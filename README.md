# Remora

A fast, native and simple remote desktop client for the Mac that speaks both RDP and VNC, and gives your AI agents computer use on every remote machine you connect to.

> [!WARNING]
> Remora is in early development and not ready for everyday use yet. There is no release, and things will change and break.

<p align="center">
  <img src="https://github.com/user-attachments/assets/af53e6e8-4ed0-4c74-8fca-7f22c9cf1403" width="100%" alt="Remora switching between macOS, Debian and Windows sessions in one window">
</p>

## Highlights

- **Fast and sharp**: A Metal renderer and H.264 decoded by VideoToolbox keep the remote desktop sharp and responsive, at full Retina resolution on RDP.
- **Computer use for AI agents**: Through the `remora` CLI, your agents see, click and type on any remote machine while you watch, and you can take over at any moment.
- **Screenshots and recordings**: Capture a screenshot or record HEVC video, even from a tab you are not looking at.
- **Secure VNC**: VeNCrypt with certificate TLS and no fallback to a weaker method, plus Apple Remote Desktop sign-in for Macs.
- **CLI**: `remora` can do almost everything the app can. Run `remora --help` to see it, and `remora skill install` to teach your agents.

## License

Remora is open source under the [GNU GPL v3](LICENSE).
