//go:build ios

package mobile

import "masterdnsvpn-go/internal/mobile"

// MobilePacketWriter receives outbound IP packets from the iOS packet bridge.
// The PacketTunnelProvider must write each packet back to NEPacketTunnelFlow.
type MobilePacketWriter interface {
	WritePacket(packet []byte)
}

// StartQueuedPacketBridge starts the iOS packet bridge and exposes outbound
// packets via ReadQueuedPacket. This avoids Swift/Objective-C callback naming
// edge cases in gomobile.
func StartQueuedPacketBridge(mtu int32, socksAddr string) error {
	return mobile.StartQueuedPacketBridge(mtu, socksAddr)
}

// ReadQueuedPacket returns one outbound packet or nil on timeout.
func ReadQueuedPacket(timeoutMillis int32) []byte {
	return mobile.ReadQueuedPacket(timeoutMillis)
}

// StartPacketBridge starts the iOS packet bridge.
//
// Unlike Android's StartTunBridge, iOS NetworkExtension does not expose a raw
// TUN file descriptor. The provider reads packets from NEPacketTunnelFlow and
// injects them via InjectPacket; outbound packets are delivered to writer.
func StartPacketBridge(mtu int32, socksAddr string, writer MobilePacketWriter) error {
	if writer == nil {
		return mobile.StartPacketBridge(mtu, socksAddr, nil)
	}
	return mobile.StartPacketBridge(mtu, socksAddr, func(packet []byte) {
		writer.WritePacket(packet)
	})
}

// InjectPacket injects one inbound IP packet read from NEPacketTunnelFlow.
func InjectPacket(packet []byte) error {
	return mobile.InjectPacket(packet)
}

// StopPacketBridge stops the iOS packet bridge.
func StopPacketBridge() {
	mobile.StopPacketBridge()
}

// IsPacketBridgeRunning reports whether the iOS packet bridge is active.
func IsPacketBridgeRunning() bool {
	return mobile.IsPacketBridgeRunning()
}
