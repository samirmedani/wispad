# Protocole WispadSync v1 (BYOS chiffré de bout en bout)

Wispad est 100 % open source et n'héberge aucun serveur central. La synchronisation multiplateforme (macOS, iOS, Windows) est entièrement **facultative** et repose sur le stockage de l'utilisateur (**BYOS** : Bring Your Own Storage) avec chiffrement de bout en bout côté client.

## Principes

- **Texte seul (quelques kilo-octets)** : seuls les textes et métadonnées sont synchronisés (dictées, notes de réunion, dictionnaire personnel, refus d'apprentissage et réglages d'écriture portables).
- **L'audio reste local** : aucun fichier WAV n'est jamais téléversé. Une dictée enregistrée sur un autre appareil conserve sa provenance (`sourceDeviceId`, `sourceDeviceName`, `sourceDevicePlatform`) et affiche dans l'interface que l'audio reste sur cet appareil.
- **Zéro clé API synchronisée** : les clés API (xAI, OpenAI, DeepSeek, etc.) restent strictement locales sur chaque appareil.
- **Zéro conflit d'écriture** : chaque appareil n'écrit que dans son propre préfixe `devices/<deviceId>/` ; la fusion est déterministe (Last-Write-Wins par `updatedAt` + pierres tombales `deletedAt`).

## Supports pris en charge

1. **Dossier synchronisé** : iCloud Drive, OneDrive, Dropbox, Google Drive ou Syncthing.
2. **Cloudflare R2 / S3** : tout bucket compatible S3 avec signature AWS SigV4 (Cloudflare R2 gratuit 10 Go, Backblaze B2, MinIO, AWS S3).
3. **WebDAV** : Nextcloud, ownCloud, NAS Synology ou serveur WebDAV standard.

## Format cryptographique

- **Clé maître (`syncKey`)** : 32 octets aléatoires (256 bits), encodés en base64url sans padding (43 caractères).
- **Dérivation de clé** : `HKDF-SHA256(ikm: syncKey, salt: "wispad-sync-v1", info: "vault-aes256gcm") -> 32 octets`.
- **Identifiant de coffre (`vaultId`)** : 16 caractères hexadécimaux minuscules correspondant aux 8 premiers octets de `SHA256("wispad-vault-id-v1:" || syncKey)`.
- **Enveloppe chiffrée (`.wsp.enc`)** :
  - Octets `0..3` : en-tête ASCII `"WSP1"`
  - Octets `4..15` : nonce aléatoire de 12 octets
  - Octets `16..N-17` : texte chiffré AES-256-GCM
  - Octets `N-16..N-1` : balise d'authentification GCM de 16 octets
  - **AAD (Additional Authenticated Data)** : UTF-8 de `"wispad-sync-v1:" + cheminRelatif` (ex. `wispad-sync-v1:devices/dev-1/000001.wsp.enc`), empêchant toute substitution de fichier.

## Arborescence dans le stockage

```text
manifest.json
devices/
  <deviceId>/
    000001.wsp.enc
    000002.wsp.enc
```

- `manifest.json` (en clair, sans aucune donnée personnelle) : `{"format":"wispad-sync","version":1,"vaultId":"<16hex>","createdAt":<timestamp>}`.
- Chaque fichier `.wsp.enc` déchiffré est un JSON `SyncDelta` contenant `version`, `deviceId`, `deviceName`, `devicePlatform`, `sequence`, `createdAt`, `dictations`, `meetings`, `dictionary`, `refusals` et optionnellement `sharedSettings` (`{ "updatedAt": <Double>, "fieldsJSON": "<JSON>" }`).

## Appairage (QR code / URI)

Format d'URI : `wispad-sync://v1?data=<base64url-sans-padding du JSON SyncPairingConfig>`.
Ce lien contient la clé locale et l'accès au stockage choisi : il doit rester privé.
