# Local patches to swift-nio-ssh 0.15.0

Source: https://github.com/apple/swift-nio-ssh at tag 0.15.0. When you upgrade, apply these changes again.

## RSA user keys

- `NIOSSHPrivateKey(rsaKey:)`, plus `.rsa` cases in the private key, public key, signature, and certified key types (`_CryptoExtras` RSA).
- Signatures use PKCS#1 v1.5 with SHA-512 (`rsa-sha2-512`). The code also reads and verifies `rsa-sha2-256` signatures. It does not make SHA-1 `ssh-rsa` signatures.
- `NIOSSHPublicKey.userAuthAlgorithm` gives `rsa-sha2-512` for publickey user auth and its signed payload. The key blob keeps the `ssh-rsa` type.
- The server side accepts `rsa-sha2-*` names for `ssh-rsa` keys.
- RSA is not a host key algorithm.

## Agent forwarding

- `SSHChannelType.agentForwarding` / channel open type `auth-agent@openssh.com` (read and write).
- `SSHChannelRequestEvent.AgentForwardingRequest` / channel request `auth-agent-req@openssh.com`.
- `NIOSSHPrivateKey.agentSignature(for:rsaSHA256:)` returns a wire-format signature over arbitrary data for agent sign requests.
