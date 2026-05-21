# MasterDnsVPN для iOS

Это iOS-клиент с двумя режимами:

- полноценный VPN через `NetworkExtension Packet Tunnel`;
- локальный SOCKS для совместимости, когда нужен внешний клиент.

Приложение использует тот же `client_config.toml`, что Android-версия, и отдельный `client_resolvers.txt`.

## Что уже есть

- несколько профилей с выбором активного, созданием, копированием и удалением;
- импорт Android/desktop `client_config.toml`;
- импорт и ручное редактирование `client_resolvers.txt`;
- запуск системного VPN и отдельного локального SOCKS;
- копирование SOCKS-ссылки, TOML и списка резолверов;
- экран состояния и живые логи ядра из Packet Tunnel/локального SOCKS.

Часть Android-функций зависит от возможностей платформы. На iOS нет прямого аналога Android Hotspot Sharing и per-app VPN без специальных entitlement/MDM-настроек, поэтому основной упор сделан на профили, локальный SOCKS и системный Packet Tunnel.

## Сборка

1. В `ios/project.yml` замени:
   - `APP_BUNDLE_ID`;
   - `APP_GROUP_ID`;
   - `DEVELOPMENT_TEAM`.
2. У сертификата и provisioning profile должен быть entitlement `packet-tunnel-provider`.
3. Собери Go-фреймворк:

```bash
bash ./ios/Scripts/build_gomobile_ios.sh
```

4. Сгенерируй Xcode-проект и собери:

```bash
cd ios
xcodegen generate
xcodebuild -project MasterDnsVPNiOS.xcodeproj -scheme MasterDnsVPN -configuration Release -sdk iphoneos build
```

GitHub Actions собирает unsigned IPA. Его можно подписать отдельно, но без настоящего NetworkExtension entitlement VPN-туннель не стартует.
