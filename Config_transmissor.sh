#!/bin/bash
echo "====================================="
echo " Transmissor MP3 - Configurável (2026)"
echo "====================================="
echo

# =============================================
#  CONFIGURAÇÃO DO ÁUDIO - Edite aqui apenas!
# =============================================
SAMPLE_RATE=48000          # Taxa de amostragem (Hz). 48000 é compatível com microfones modernos
CHANNELS=2                 # 1 = mono, 2 = estéreo (recomendado 2 para evitar problemas)
BITRATE=128k               # Qualidade do MP3: 96k, 128k, 160k, 192k, 256k...
BUFFER_SIZE=8192           # Tamanho do buffer no navegador (4096 ou 8192).
FFMPEG_RESAMPLE="aresample=${SAMPLE_RATE}:async=1"  # Filtro para corrigir desvio de clock/tempo

# =============================================
#  CONFIG ICECAST (mantenha como está ou altere)
# =============================================
HOST="vps64181.publiccloud.com.br"
PORT="8001"
MOUNT="/live"
USER="source"
PASS="test123"
ICECAST="icecast://$USER:$PASS@$HOST:$PORT$MOUNT"

echo "Configuração de áudio atual:"
echo "  Sample Rate   : $SAMPLE_RATE Hz"
echo "  Canais        : $CHANNELS (1=mono, 2=estéreo)"
echo "  Bitrate MP3   : $BITRATE"
echo "  Buffer JS     : $BUFFER_SIZE samples"
echo ""
echo "Icecast destino:"
echo "$ICECAST"
echo ""

# ===== LIMPEZA =====
pkill node 2>/dev/null
pkill ffmpeg 2>/dev/null
pkill cloudflared 2>/dev/null

# ===== INSTALAÇÃO =====
apt update -y
apt install -y nodejs npm ffmpeg curl lsof

# ===== PORTA LIVRE =====
PORTA=3000
while lsof -i:$PORTA >/dev/null 2>&1; do
  PORTA=$((PORTA+1))
done
echo "Porta local escolhida: $PORTA"
echo ""

# ===== PROJETO =====
DIR=~/stream-mp3
mkdir -p "$DIR"
cd "$DIR"
npm init -y >/dev/null 2>&1
npm install ws >/dev/null 2>&1

# ===== SERVER.JS - com variáveis injetadas =====
cat > server.js <<EOF
const http = require('http');
const WebSocket = require('ws');
const { spawn } = require('child_process');

const ICECAST = "${ICECAST}";
const PORT = ${PORTA};

let ffmpeg = null;

const server = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(\`
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Transmissor MP3</title>
    <style>
        body { font-family: Arial, sans-serif; background:#111; color:#fff;
        text-align:center; padding:40px; }
        h2 { color:#0f0; }
        button { padding:15px 40px; margin:10px; font-size:20px;
        cursor:pointer; border:none; border-radius:8px; }
        #start { background:#4CAF50; color:white; }
        #stop { background:#f44336; color:white; }
        #status { font-size:18px; margin-top:20px; }
    </style>
</head>
<body>
    <h2>Transmissor MP3 ao Vivo</h2>
    <button id="start" onclick="start()">Iniciar Transmissão</button>
    <button id="stop" onclick="stop()" disabled>Parar</button>
    <p id="status">Aguardando...</p>

    <script>
    let ws = null;
    let audioContext = null;
    let processor = null;
    let input = null;
    let stream = null;

    async function start() {
        try {
            stream = await navigator.mediaDevices.getUserMedia({ audio: true });
            ws = new WebSocket("wss://" + location.host);

            audioContext = new AudioContext({ sampleRate: ${SAMPLE_RATE} });
            input = audioContext.createMediaStreamSource(stream);
            processor = 
            audioContext.createScriptProcessor(${BUFFER_SIZE}, ${CHANNELS}, ${CHANNELS});

            input.connect(processor);
            processor.connect(audioContext.destination);

            processor.onaudioprocess = (e) => {
                const left = e.inputBuffer.getChannelData(0);
                let right = (e.inputBuffer.numberOfChannels > 1) ?
                e.inputBuffer.getChannelData(1) : left;

                const buffer = new ArrayBuffer(left.length * 4);
                const view = new DataView(buffer);

                for (let i = 0; i < left.length; i++) {
                    const l = Math.max(-1, Math.min(1, left[i])) * 0x7FFF;
                    const r = Math.max(-1, Math.min(1, right[i])) * 0x7FFF;
                    view.setInt16(i * 4    , l, true);
                    view.setInt16(i * 4 + 2, r, true);
                }

                if (ws.readyState === WebSocket.OPEN) {
                    ws.send(buffer);
                }
            };

            document.getElementById('status').textContent = "Transmitindo... Fale no microfone!";
            document.getElementById('start').disabled = true;
            document.getElementById('stop').disabled = false;

        } catch (err) {
            alert("Erro ao acessar microfone: " + err.message);
        }
    }

    function stop() {
        if (processor) processor.disconnect();
        if (input) input.disconnect();
        if (audioContext) audioContext.close();
        if (stream) stream.getTracks().forEach(track => track.stop());
        if (ws) ws.close();

        document.getElementById('status').textContent = "Parado";
        document.getElementById('start').disabled = false;
        document.getElementById('stop').disabled = true;
    }
    </script>
</body>
</html>
    \`);
});

const wss = new WebSocket.Server({ server });

wss.on('connection', (ws) => {
    console.log("Cliente conectado");

    if (!ffmpeg) {
        console.log("Iniciando FFmpeg...");
        ffmpeg = spawn('ffmpeg', [
            '-f', 's16le',
            '-ar', '${SAMPLE_RATE}',
            '-ac', '${CHANNELS}',
            '-i', '-',
            '-af', '${FFMPEG_RESAMPLE}',
            '-acodec', 'libmp3lame',
            '-b:a', '${BITRATE}',
            '-content_type', 'audio/mpeg',
            '-f', 'mp3',
            ICECAST
        ]);

        ffmpeg.stderr.on('data', (d) => {
            console.log("[FFmpeg] " + d.toString().trim());
        });

        ffmpeg.on('close', (code) => {
            console.log("FFmpeg finalizado (código " + code + ")");
            ffmpeg = null;
        });
    }

    ws.on('message', (msg) => {
        if (ffmpeg && !ffmpeg.killed) {
            ffmpeg.stdin.write(msg);
        }
    });

    ws.on('close', () => {
        console.log("Cliente desconectado");
    });
});

server.listen(PORT, () => {
    console.log("Servidor rodando na porta " + PORT);
});
EOF

# ===== CLOUDFLARED =====
echo "Instalando/Atualizando cloudflared..."
cd "$DIR"
rm -f cloudflared
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
-o cloudflared
chmod +x cloudflared

# ===== INICIAR =====
echo "Iniciando servidor Node.js..."
node server.js > server.log 2>&1 &

sleep 3

echo "Iniciando Cloudflare Tunnel..."
./cloudflared tunnel --url http://localhost:$PORTA > tunnel.log 2>&1 &

echo "Aguardando link (10-15 segundos)..."
sleep 12

LINK=$(grep -o 'https://[^ ]*trycloudflare.com' tunnel.log | head -n 1)

echo ""
echo "====================================="
echo "               PRONTO!               "
echo "====================================="
echo ""
echo "LINK DO TRANSMISSOR:"
echo "$LINK"
echo ""
echo "STREAM URL (para ouvir):"
echo "$ICECAST"
echo ""
echo "Logs úteis:"
echo "  tail -f ~/stream-mp3/server.log    # FFmpeg e conexões"
echo "  tail -f ~/stream-mp3/tunnel.log    # Tunnel Cloudflare"
echo ""
echo "Lembrete: ajuste SAMPLE_RATE, CHANNELS, BITRATE no topo do script se mudar de microfone/PC."
echo "Recomendação: mantenha SAMPLE_RATE=48000 no Liquidsoap também (%mp3(samplerate=48000,...))"
