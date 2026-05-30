#!/bin/bash

echo "====================================="
echo "        MediaCore Installer"
echo "====================================="
echo

AUTO_DOMAIN=$(hostname -f 2>/dev/null)

if [[ -z "$AUTO_DOMAIN" || "$AUTO_DOMAIN" == "localhost" ]]; then
  AUTO_DOMAIN=
  $(nslookup $(hostname -I | awk '{print $1}') 2>/dev/null | awk -F'= ' '/
  name =/ {print $2}' | sed 's/\.$//')
fi

echo
read -p "Enter your domain (example: $AUTO_DOMAIN): " DOMAIN

if [ -z "$DOMAIN" ]; then
  DOMAIN="$AUTO_DOMAIN"
fi

echo
echo "Enter Icecast / Live password:"
echo "(IMPORTANT: This MUST be the same password that will be configured"
echo "during Icecast installation.)"
read -s PASSWORD
echo
echo "Confirm password:"
read -s PASSWORD2
echo

if [ "$PASSWORD" != "$PASSWORD2" ]; then
  echo "Passwords do not match. Aborting."
  exit 1
fi

echo
echo "Updating system..."
apt update && apt upgrade -y

echo
echo "Installing packages..."
apt install -y icecast2 liquidsoap apache2

echo
echo "Creating media folders..."
mkdir -p /home/media/music
mkdir -p /home/media/jingles
mkdir -p /etc/liquidsoap

echo
echo "Creating Liquidsoap configuration..."

cat > /etc/liquidsoap/mediacore.liq <<EOF
settings.init.allow_root.set(true)

set("log.file.path","/var/log/liquidsoap.log")
set("server.telnet",false)

music = playlist("/home/media/music", mode="random")
jingles = playlist("/home/media/jingles", mode="random")

program = rotate(weights=[5,1], [music, jingles])
program = mksafe(program)

live = input.harbor("live", port=8001, password="$PASSWORD")

final = fallback(track_sensitive=false, [live, program])

output.icecast(%mp3(bitrate=128, samplerate=44100, stereo=true),
  host="localhost",
  port=8000,
  password="$PASSWORD",
  mount="live.mp3",
  name="MediaCore",
  description="24/7 Live Streaming",
  final
)
EOF

echo
echo "Creating systemd service..."

cat > /etc/systemd/system/mediacore.service <<EOF
[Unit]
Description=MediaCore Streaming Service
After=network.target

[Service]
ExecStart=/usr/bin/liquidsoap /etc/liquidsoap/mediacore.liq
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mediacore
systemctl start mediacore

echo
echo "Creating HTML player..."

cat > /var/www/html/index.html <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>MediaCore</title>
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<style>
body {
  margin:0;
  background:#111;
  color:#fff;
  font-family:Arial;
  display:flex;
  justify-content:center;
  align-items:center;
  height:100vh;
}
.player {
  background:#222;
  padding:30px;
  border-radius:20px;
  text-align:center;
}
button {
  padding:15px 30px;
  font-size:18px;
  border:none;
  border-radius:50px;
  cursor:pointer;
}
</style>
</head>
<body>
<div class="player">
  <h1>MediaCore</h1>
  <button onclick="playStream()">LISTEN NOW</button>
  <audio id="stream">
    <source src="http://$DOMAIN:8000/live.mp3" type="audio/mpeg">
  </audio>
</div>

<script>
function playStream() {
  document.getElementById("stream").play();
}
</script>
</body>
</html>
EOF

systemctl restart apache2

echo
echo "====================================="
echo " Installation Completed!"
echo "====================================="
echo
echo "Now:"
echo "1) Upload media files to: /home/media/music"
echo "2) Upload jingles to: /home/media/jingles"
echo
echo "Stream URL:"
echo "http://$DOMAIN:8000/live.mp3"
echo
echo "Website Player:"
echo "http://$DOMAIN/"
echo
echo "Live Encoder Settings:"
echo "Server: $DOMAIN"
echo "Port: 8001"
echo "Mount: live"
echo "Username: source"
echo "Password: (the one you typed)"
