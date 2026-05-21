//go:build ios

package mobile

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"masterdnsvpn-go/internal/client"

	"github.com/sagernet/gvisor/pkg/buffer"
	"github.com/sagernet/gvisor/pkg/tcpip"
	"github.com/sagernet/gvisor/pkg/tcpip/adapters/gonet"
	"github.com/sagernet/gvisor/pkg/tcpip/header"
	"github.com/sagernet/gvisor/pkg/tcpip/link/channel"
	"github.com/sagernet/gvisor/pkg/tcpip/network/ipv4"
	"github.com/sagernet/gvisor/pkg/tcpip/network/ipv6"
	"github.com/sagernet/gvisor/pkg/tcpip/stack"
	"github.com/sagernet/gvisor/pkg/tcpip/transport/tcp"
	"github.com/sagernet/gvisor/pkg/tcpip/transport/udp"
	"github.com/sagernet/gvisor/pkg/waiter"
)

const packetNICID tcpip.NICID = 1

type PacketWriteFunc func([]byte)

var (
	packetMu       sync.Mutex
	packetCancel   context.CancelFunc
	packetDone     chan struct{}
	packetEndpoint *channel.Endpoint
	packetWriter   PacketWriteFunc
	packetOutCh    chan []byte
	packetUp       atomic.Int64
	packetDown     atomic.Int64
)

const (
	packetQueueSize = 4096
	packetMTU       = 1500

	relayBufSize           = 64 * 1024
	tcpMaxInFlight         = 4096
	tcpDialTimeout         = 5 * time.Second
	socks5HandshakeTimeout = 10 * time.Second
	udpReadTimeout         = 5 * time.Second
)

var relayBufPool = sync.Pool{
	New: func() any {
		b := make([]byte, relayBufSize)
		return &b
	},
}

func getRelayBuf() []byte  { return *(relayBufPool.Get().(*[]byte)) }
func putRelayBuf(b []byte) { relayBufPool.Put(&b) }

type halfCloser interface {
	CloseWrite() error
}

func StartPacketBridge(mtu int32, socksAddr string, writer PacketWriteFunc) error {
	packetMu.Lock()
	defer packetMu.Unlock()

	if packetCancel != nil {
		return errors.New("packet bridge already running")
	}
	if writer == nil {
		return errors.New("packet writer is nil")
	}
	if socksAddr == "" {
		return errors.New("socksAddr must not be empty")
	}

	bridgeMTU := int(mtu)
	if bridgeMTU <= 0 {
		bridgeMTU = packetMTU
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	packetCancel = cancel
	packetDone = done
	packetWriter = writer
	packetUp.Store(0)
	packetDown.Store(0)

	go func() {
		defer func() {
			packetMu.Lock()
			packetCancel = nil
			packetDone = nil
			packetEndpoint = nil
			packetWriter = nil
			packetOutCh = nil
			packetMu.Unlock()
			close(done)
		}()
		if err := runPacketBridge(ctx, bridgeMTU, socksAddr, writer); err != nil && !errors.Is(err, context.Canceled) {
			packetErr("packet bridge exited: %v", err)
		}
	}()

	return nil
}

func StartQueuedPacketBridge(mtu int32, socksAddr string) error {
	out := make(chan []byte, packetQueueSize)

	err := StartPacketBridge(mtu, socksAddr, func(packet []byte) {
		select {
		case out <- packet:
		default:
			select {
			case <-out:
			default:
			}
			select {
			case out <- packet:
			default:
			}
		}
	})
	if err != nil {
		return err
	}

	packetMu.Lock()
	packetOutCh = out
	packetMu.Unlock()
	return nil
}

func ReadQueuedPacket(timeoutMillis int32) []byte {
	packetMu.Lock()
	out := packetOutCh
	packetMu.Unlock()
	if out == nil {
		return nil
	}

	if timeoutMillis <= 0 {
		select {
		case pkt := <-out:
			return pkt
		default:
			return nil
		}
	}

	timer := time.NewTimer(time.Duration(timeoutMillis) * time.Millisecond)
	defer timer.Stop()
	select {
	case pkt := <-out:
		return pkt
	case <-timer.C:
		return nil
	}
}

func InjectPacket(packet []byte) error {
	if len(packet) < 1 {
		return errors.New("empty packet")
	}

	packetMu.Lock()
	ep := packetEndpoint
	packetMu.Unlock()
	if ep == nil {
		return errors.New("packet bridge is not running")
	}

	var proto tcpip.NetworkProtocolNumber
	switch packet[0] >> 4 {
	case 4:
		proto = ipv4.ProtocolNumber
	case 6:
		proto = ipv6.ProtocolNumber
	default:
		return fmt.Errorf("unsupported IP version: %d", packet[0]>>4)
	}

	payload := make([]byte, len(packet))
	copy(payload, packet)
	pkt := stack.NewPacketBuffer(stack.PacketBufferOptions{
		Payload: buffer.MakeWithData(payload),
	})
	ep.InjectInbound(proto, pkt)
	pkt.DecRef()
	packetUp.Add(int64(len(packet)))
	return nil
}

func StopPacketBridge() {
	packetMu.Lock()
	cancel := packetCancel
	done := packetDone
	packetMu.Unlock()

	if cancel != nil {
		cancel()
	}
	if done != nil {
		<-done
	}
}

func IsPacketBridgeRunning() bool {
	packetMu.Lock()
	defer packetMu.Unlock()
	return packetCancel != nil
}

func PacketBridgeBandwidth() (int64, int64) {
	return packetUp.Load(), packetDown.Load()
}

func runPacketBridge(ctx context.Context, mtu int, socksAddr string, writer PacketWriteFunc) error {
	packetLog("starting iOS packet bridge: mtu=%d socks=%s", mtu, socksAddr)

	origDial := client.DialUDPFunc
	origListen := client.ListenUDPFunc
	client.DialUDPFunc = net.DialUDP
	client.ListenUDPFunc = net.ListenUDP
	defer func() {
		client.DialUDPFunc = origDial
		client.ListenUDPFunc = origListen
	}()

	s := stack.New(stack.Options{
		NetworkProtocols: []stack.NetworkProtocolFactory{
			ipv4.NewProtocol,
			ipv6.NewProtocol,
		},
		TransportProtocols: []stack.TransportProtocolFactory{
			tcp.NewProtocol,
			udp.NewProtocol,
		},
	})

	delay := tcpip.TCPDelayEnabled(false)
	_ = s.SetTransportProtocolOption(tcp.ProtocolNumber, &delay)
	sack := tcpip.TCPSACKEnabled(true)
	_ = s.SetTransportProtocolOption(tcp.ProtocolNumber, &sack)
	moderate := tcpip.TCPModerateReceiveBufferOption(true)
	_ = s.SetTransportProtocolOption(tcp.ProtocolNumber, &moderate)
	sendBuf := tcpip.TCPSendBufferSizeRangeOption{Min: 4096, Default: 262144, Max: 8388608}
	_ = s.SetTransportProtocolOption(tcp.ProtocolNumber, &sendBuf)
	recvBuf := tcpip.TCPReceiveBufferSizeRangeOption{Min: 4096, Default: 262144, Max: 8388608}
	_ = s.SetTransportProtocolOption(tcp.ProtocolNumber, &recvBuf)

	ep := channel.New(packetQueueSize, uint32(mtu), "")
	packetMu.Lock()
	packetEndpoint = ep
	packetMu.Unlock()

	if tcpErr := s.CreateNIC(packetNICID, ep); tcpErr != nil {
		return fmt.Errorf("packet bridge CreateNIC: %v", tcpErr)
	}
	if tcpErr := s.SetPromiscuousMode(packetNICID, true); tcpErr != nil {
		return fmt.Errorf("packet bridge SetPromiscuousMode: %v", tcpErr)
	}
	if tcpErr := s.SetSpoofing(packetNICID, true); tcpErr != nil {
		return fmt.Errorf("packet bridge SetSpoofing: %v", tcpErr)
	}
	s.SetRouteTable([]tcpip.Route{
		{Destination: header.IPv4EmptySubnet, NIC: packetNICID},
		{Destination: header.IPv6EmptySubnet, NIC: packetNICID},
	})

	go drainOutboundPackets(ctx, ep, writer)
	installPacketForwarders(ctx, s, socksAddr)

	packetLog("iOS packet bridge is active")
	<-ctx.Done()
	packetLog("iOS packet bridge shutting down")
	ep.Close()
	s.Close()
	return ctx.Err()
}

func drainOutboundPackets(ctx context.Context, ep *channel.Endpoint, writer PacketWriteFunc) {
	for {
		pkt := ep.ReadContext(ctx)
		if pkt == nil {
			return
		}
		buf := pkt.ToBuffer()
		data := buf.Flatten()
		buf.Release()
		pkt.DecRef()
		if len(data) == 0 {
			continue
		}
		packetDown.Add(int64(len(data)))
		out := make([]byte, len(data))
		copy(out, data)
		writer(out)
	}
}

func installPacketForwarders(ctx context.Context, s *stack.Stack, socksAddr string) {
	sem := make(chan struct{}, tcpMaxInFlight)

	tcpFwd := tcp.NewForwarder(s, 0, tcpMaxInFlight, func(r *tcp.ForwarderRequest) {
		id := r.ID()
		dstAddr := net.JoinHostPort(id.LocalAddress.String(), fmt.Sprintf("%d", id.LocalPort))

		var wq waiter.Queue
		ep, tcpErr := r.CreateEndpoint(&wq)
		if tcpErr != nil {
			packetErr("TCP CreateEndpoint failed for %s: %v", dstAddr, tcpErr)
			r.Complete(true)
			return
		}
		r.Complete(false)
		conn := gonet.NewTCPConn(&wq, ep)

		select {
		case sem <- struct{}{}:
		case <-time.After(2 * time.Second):
			packetErr("TCP backpressure: dropping %s", dstAddr)
			_ = conn.Close()
			return
		case <-ctx.Done():
			_ = conn.Close()
			return
		}

		go func() {
			defer func() { <-sem }()
			defer conn.Close()
			if ctx.Err() != nil {
				return
			}
			packetProxyTCP(ctx, conn, dstAddr, socksAddr)
		}()
	})
	s.SetTransportProtocolHandler(tcp.ProtocolNumber, tcpFwd.HandlePacket)

	udpFwd := udp.NewForwarder(s, func(r *udp.ForwarderRequest) bool {
		id := r.ID()
		if id.LocalPort != 53 {
			return false
		}

		dstAddr := net.JoinHostPort(id.LocalAddress.String(), fmt.Sprintf("%d", id.LocalPort))
		var wq waiter.Queue
		ep, udpErr := r.CreateEndpoint(&wq)
		if udpErr != nil {
			packetErr("UDP CreateEndpoint failed for %s: %v", dstAddr, udpErr)
			return false
		}

		conn := gonet.NewUDPConn(&wq, ep)
		go func() {
			defer conn.Close()
			if ctx.Err() != nil {
				return
			}
			packetProxyDNS(ctx, conn, dstAddr)
		}()
		return true
	})
	s.SetTransportProtocolHandler(udp.ProtocolNumber, udpFwd.HandlePacket)
}

func packetProxyTCP(ctx context.Context, src net.Conn, dstAddr string, socksAddr string) {
	host, portStr, err := net.SplitHostPort(dstAddr)
	if err != nil {
		packetErr("TCP parse %s: %v", dstAddr, err)
		return
	}
	port, err := strconv.ParseUint(portStr, 10, 16)
	if err != nil {
		packetErr("TCP port %s: %v", dstAddr, err)
		return
	}

	dialCtx, dialCancel := context.WithTimeout(ctx, tcpDialTimeout)
	defer dialCancel()
	proxy, err := (&net.Dialer{}).DialContext(dialCtx, "tcp", socksAddr)
	if err != nil {
		packetErr("TCP dial SOCKS5 for %s: %v", dstAddr, err)
		return
	}
	defer proxy.Close()

	if err := packetSocks5ConnectTCP(proxy, host, uint16(port)); err != nil {
		packetErr("TCP SOCKS5 CONNECT %s: %v", dstAddr, err)
		return
	}

	packetRelay(src, proxy)
}

func packetProxyDNS(ctx context.Context, src net.Conn, dstAddr string) {
	buf := make([]byte, 4096)
	var idleTimeouts int
	for {
		if ctx.Err() != nil {
			return
		}
		if tc, ok := src.(interface{ SetReadDeadline(time.Time) error }); ok {
			_ = tc.SetReadDeadline(time.Now().Add(udpReadTimeout))
		}

		n, readErr := src.Read(buf)
		if readErr != nil {
			if netErr, ok := readErr.(net.Error); ok && netErr.Timeout() {
				idleTimeouts++
				if idleTimeouts >= 3 {
					return
				}
				continue
			}
			return
		}
		idleTimeouts = 0
		if n == 0 {
			continue
		}

		query := make([]byte, n)
		copy(query, buf[:n])
		cl := getAnyClient()
		if cl == nil || !cl.SessionReady() {
			packetUp.Add(int64(n))
			continue
		}

		var responseWritten bool
		writeResp := func(resp []byte) {
			_, _ = src.Write(resp)
			packetDown.Add(int64(len(resp)))
			responseWritten = true
		}

		isHit := cl.ProcessDNSQuery(query, nil, writeResp)
		packetUp.Add(int64(n))
		if isHit {
			continue
		}

		deadline := time.Now().Add(5 * time.Second)
		ticker := time.NewTicker(20 * time.Millisecond)
		for !responseWritten {
			select {
			case <-ctx.Done():
				ticker.Stop()
				return
			case <-ticker.C:
				if time.Now().After(deadline) {
					ticker.Stop()
					packetLog("DNS timeout for %s", dstAddr)
					return
				}
				if cl = getAnyClient(); cl != nil && cl.SessionReady() {
					_ = cl.ProcessDNSQuery(query, nil, writeResp)
				}
			}
		}
		ticker.Stop()
	}
}

func packetSocks5ConnectTCP(conn net.Conn, host string, port uint16) error {
	_ = conn.SetDeadline(time.Now().Add(socks5HandshakeTimeout))
	defer func() { _ = conn.SetDeadline(time.Time{}) }()

	if _, err := conn.Write([]byte{0x05, 0x01, 0x00}); err != nil {
		return fmt.Errorf("auth write: %w", err)
	}
	authResp := make([]byte, 2)
	if _, err := io.ReadFull(conn, authResp); err != nil {
		return fmt.Errorf("auth read: %w", err)
	}
	if authResp[0] != 0x05 || authResp[1] != 0x00 {
		return fmt.Errorf("SOCKS5 auth failed: %v", authResp)
	}

	req := packetSocks5ConnectRequest(host, port)
	if _, err := conn.Write(req); err != nil {
		return fmt.Errorf("connect write: %w", err)
	}
	hdr := make([]byte, 4)
	if _, err := io.ReadFull(conn, hdr); err != nil {
		return fmt.Errorf("connect read: %w", err)
	}
	if hdr[1] != 0x00 {
		return fmt.Errorf("CONNECT refused, code=%d", hdr[1])
	}
	return packetDrainSocks5Addr(conn, hdr[3])
}

func packetSocks5ConnectRequest(host string, port uint16) []byte {
	if ip := net.ParseIP(host); ip != nil {
		if ip4 := ip.To4(); ip4 != nil {
			req := make([]byte, 10)
			req[0], req[1], req[2], req[3] = 0x05, 0x01, 0x00, 0x01
			copy(req[4:8], ip4)
			binary.BigEndian.PutUint16(req[8:10], port)
			return req
		}
		ip6 := ip.To16()
		req := make([]byte, 22)
		req[0], req[1], req[2], req[3] = 0x05, 0x01, 0x00, 0x04
		copy(req[4:20], ip6)
		binary.BigEndian.PutUint16(req[20:22], port)
		return req
	}

	h := []byte(host)
	req := make([]byte, 7+len(h))
	req[0], req[1], req[2], req[3] = 0x05, 0x01, 0x00, 0x03
	req[4] = byte(len(h))
	copy(req[5:], h)
	binary.BigEndian.PutUint16(req[5+len(h):], port)
	return req
}

func packetDrainSocks5Addr(conn net.Conn, atyp byte) error {
	var size int
	switch atyp {
	case 0x01:
		size = 4 + 2
	case 0x03:
		lenBuf := make([]byte, 1)
		if _, err := io.ReadFull(conn, lenBuf); err != nil {
			return err
		}
		size = int(lenBuf[0]) + 2
	case 0x04:
		size = 16 + 2
	default:
		return fmt.Errorf("socks5: unknown atyp=%d", atyp)
	}
	_, err := io.ReadFull(conn, make([]byte, size))
	return err
}

func packetRelay(a, b net.Conn) {
	var wg sync.WaitGroup
	wg.Add(2)

	copyHalf := func(dst, src net.Conn, counter *atomic.Int64) {
		defer wg.Done()
		buf := getRelayBuf()
		defer putRelayBuf(buf)

		for {
			n, readErr := src.Read(buf)
			if n > 0 {
				wrote, writeErr := dst.Write(buf[:n])
				if wrote > 0 {
					counter.Add(int64(wrote))
				}
				if writeErr != nil {
					break
				}
			}
			if readErr != nil {
				break
			}
		}
		if hc, ok := dst.(halfCloser); ok {
			_ = hc.CloseWrite()
		} else {
			_ = dst.Close()
		}
	}

	go copyHalf(b, a, &packetUp)
	copyHalf(a, b, &packetDown)
	wg.Wait()
}

func packetLog(format string, args ...any) {
	msg := fmt.Sprintf("[IOS-PACKET-BRIDGE] "+format, args...)
	log.Print(msg)
	deliverLogEntry(LogEntry{
		Level:     LogLevelInfo,
		Timestamp: time.Now().Format("2006-01-02 15:04:05"),
		Message:   msg,
	})
}

func packetErr(format string, args ...any) {
	msg := fmt.Sprintf("[IOS-PACKET-BRIDGE] "+format, args...)
	log.Print(msg)
	deliverLogEntry(LogEntry{
		Level:     LogLevelError,
		Timestamp: time.Now().Format("2006-01-02 15:04:05"),
		Message:   msg,
	})
}
