# Yts-to-Torbox Bulk Downloader
A simple script that pulls every single YTS torrent hash, checks Torbox cache status, prioritises based on x265>x264, bluray>web, then add the cached hashes.

## Usage
```
curl -sL https://raw.githubusercontent.com/Lumi-Script/yts-to-torbox/refs/heads/main/yts-torbox.sh | bash -s -- -a <api_key> [-l <lang>] [-q <qualities>] [--include-porn]
```

Example (defaults to English, qualities 1080p, 2160p, 3D (480p/720p fallback if no higher available) and no adult content)
```
curl -sL https://raw.githubusercontent.com/Lumi-Script/yts-to-torbox/refs/heads/main/yts-torbox.sh | bash -s -- -a xxxxxxxxxxxxxxxxx
```

### Paramters
| Paramter       | Description                                  | Example             |
|----------------|----------------------------------------------|---------------------|
| -a             | Torbox API Key (Required)                    | -a xxxxxxxxxxxxxxxx |
| -l             | Language (optional, default "en")            | -l "en"             |
| --include-porn | Disable the adult content (porn/gore) filter | --include-porn      |


## Notes
- Torbox has implemented a stated limit of 60/hour for adding torrents which aren't cached, I'm oddly seeing this limit applied to this script too.
- Given this, this script can take literally a week to run. Use screen or similar to run in the background.


## Disclaimer
- THIS CODE COMES WITH NO WARRANTY - USE AT YOUR OWN RISK. 
- TORBOX MAY CONSIDER THIS A BREACH OF FAIR USE AND BAN YOUR ACCOUNT.
