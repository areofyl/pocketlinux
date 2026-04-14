#!/bin/sh
# Bundle pocketlinux into a single self-contained HTML file
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$SCRIPT_DIR/build"
VENDOR="$SCRIPT_DIR/vendor/v86"
OUT="$SCRIPT_DIR/pocketlinux.html"
CACHE="$SCRIPT_DIR/build/bundle-cache"

mkdir -p "$CACHE"

echo "==> Encoding assets..."

# Compress rootfs with gzip before base64
if [ ! -f "$CACHE/rootfs.ext4.gz.b64" ] || [ "$BUILD/rootfs.ext4" -nt "$CACHE/rootfs.ext4.gz.b64" ]; then
    echo "  rootfs.ext4 (compress + encode)..."
    gzip -1 -c "$BUILD/rootfs.ext4" | base64 -w0 > "$CACHE/rootfs.ext4.gz.b64"
fi

# Base64 encode other binary assets
for f in vmlinuz initramfs.img; do
    if [ ! -f "$CACHE/$f.b64" ] || [ "$BUILD/$f" -nt "$CACHE/$f.b64" ]; then
        echo "  $f..."
        base64 -w0 < "$BUILD/$f" > "$CACHE/$f.b64"
    fi
done

for f in seabios.bin vgabios.bin; do
    if [ ! -f "$CACHE/$f.b64" ] || [ "$VENDOR/bios/$f" -nt "$CACHE/$f.b64" ]; then
        echo "  $f..."
        base64 -w0 < "$VENDOR/bios/$f" > "$CACHE/$f.b64"
    fi
done

if [ ! -f "$CACHE/v86.wasm.b64" ] || [ "$VENDOR/build/v86.wasm" -nt "$CACHE/v86.wasm.b64" ]; then
    echo "  v86.wasm..."
    base64 -w0 < "$VENDOR/build/v86.wasm" > "$CACHE/v86.wasm.b64"
fi

# Fetch xterm.js assets if not cached
if [ ! -f "$CACHE/xterm.min.js" ]; then
    echo "  fetching xterm.js..."
    curl -sL "https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/lib/xterm.min.js" -o "$CACHE/xterm.min.js"
fi
if [ ! -f "$CACHE/xterm.min.css" ]; then
    echo "  fetching xterm.css..."
    curl -sL "https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/css/xterm.min.css" -o "$CACHE/xterm.min.css"
fi
if [ ! -f "$CACHE/addon-fit.min.js" ]; then
    echo "  fetching xterm-addon-fit..."
    curl -sL "https://cdn.jsdelivr.net/npm/@xterm/addon-fit@0.10.0/lib/addon-fit.min.js" -o "$CACHE/addon-fit.min.js"
fi

echo "==> Building HTML..."

cat > "$OUT" << 'HTMLHEADER'
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>pocketlinux</title>
<style>
HTMLHEADER

# Inline xterm CSS
cat "$CACHE/xterm.min.css" >> "$OUT"

cat >> "$OUT" << 'CSSBLOCK'

* { margin: 0; padding: 0; box-sizing: border-box; }
body {
    background: #0c0c0c;
    display: flex;
    flex-direction: column;
    height: 100vh;
    overflow: hidden;
}
#status {
    color: #888;
    font: 13px monospace;
    padding: 4px 8px;
    background: #111;
    border-bottom: 1px solid #222;
}
#terminal-container {
    flex: 1;
    padding: 4px;
}
.xterm { height: 100%; }
</style>
</head>
<body>
<div id="status">loading assets...</div>
<div id="terminal-container"></div>
<div id="screen_container" style="display:none">
    <div style="white-space:pre;font:14px monospace;line-height:14px"></div>
    <canvas></canvas>
</div>
<script>
CSSBLOCK

# Inline xterm.js
cat "$CACHE/xterm.min.js" >> "$OUT"
echo "" >> "$OUT"

# Inline fit addon
cat "$CACHE/addon-fit.min.js" >> "$OUT"
echo "" >> "$OUT"

# Inline libv86.js
cat "$VENDOR/build/libv86.js" >> "$OUT"
echo "" >> "$OUT"

# Inline the boot script with embedded assets
cat >> "$OUT" << 'SCRIPTSTART'

// Decode base64 to ArrayBuffer
function b64toAB(b64) {
    var bin = atob(b64);
    var len = bin.length;
    var buf = new ArrayBuffer(len);
    var view = new Uint8Array(buf);
    for (var i = 0; i < len; i++) view[i] = bin.charCodeAt(i);
    return buf;
}

// Decode gzipped base64 using DecompressionStream
async function b64gzToAB(b64) {
    var compressed = b64toAB(b64);
    var ds = new DecompressionStream("gzip");
    var writer = ds.writable.getWriter();
    var reader = ds.readable.getReader();
    var chunks = [];
    writer.write(new Uint8Array(compressed));
    writer.close();
    while (true) {
        var r = await reader.read();
        if (r.done) break;
        chunks.push(r.value);
    }
    var total = 0;
    for (var i = 0; i < chunks.length; i++) total += chunks[i].length;
    var result = new Uint8Array(total);
    var offset = 0;
    for (var i = 0; i < chunks.length; i++) {
        result.set(chunks[i], offset);
        offset += chunks[i].length;
    }
    return result.buffer;
}

var ASSETS = {
SCRIPTSTART

# Embed base64 data
printf '    bios: "' >> "$OUT"
cat "$CACHE/seabios.bin.b64" >> "$OUT"
echo '",' >> "$OUT"

printf '    vga_bios: "' >> "$OUT"
cat "$CACHE/vgabios.bin.b64" >> "$OUT"
echo '",' >> "$OUT"

printf '    wasm: "' >> "$OUT"
cat "$CACHE/v86.wasm.b64" >> "$OUT"
echo '",' >> "$OUT"

printf '    bzimage: "' >> "$OUT"
cat "$CACHE/vmlinuz.b64" >> "$OUT"
echo '",' >> "$OUT"

printf '    initrd: "' >> "$OUT"
cat "$CACHE/initramfs.img.b64" >> "$OUT"
echo '",' >> "$OUT"

printf '    hda_gz: "' >> "$OUT"
cat "$CACHE/rootfs.ext4.gz.b64" >> "$OUT"
echo '",' >> "$OUT"

cat >> "$OUT" << 'SCRIPTEND'
};

window.onload = async function() {
    var statusEl = document.getElementById("status");

    statusEl.textContent = "decompressing rootfs...";
    var hdaBuf = await b64gzToAB(ASSETS.hda_gz);

    statusEl.textContent = "decoding assets...";
    var biosBuf = b64toAB(ASSETS.bios);
    var vgaBuf = b64toAB(ASSETS.vga_bios);
    var wasmBuf = b64toAB(ASSETS.wasm);
    var bzimageBuf = b64toAB(ASSETS.bzimage);
    var initrdBuf = b64toAB(ASSETS.initrd);

    // Free the base64 strings
    ASSETS = null;

    statusEl.textContent = "booting...";

    var term = new Terminal({
        cursorBlink: true,
        fontSize: 15,
        fontFamily: "monospace",
        theme: {
            background: "#0c0c0c",
            foreground: "#cccccc",
            cursor: "#cccccc",
        },
    });

    var fitAddon = new FitAddon.FitAddon();
    term.loadAddon(fitAddon);
    term.open(document.getElementById("terminal-container"));
    fitAddon.fit();
    window.addEventListener("resize", function() { fitAddon.fit(); });

    var emulator = new V86({
        wasm_fn: async function(imports) {
            var mod = await WebAssembly.compile(wasmBuf);
            var inst = await WebAssembly.instantiate(mod, imports);
            return inst.exports;
        },
        memory_size: 128 * 1024 * 1024,
        vga_memory_size: 2 * 1024 * 1024,
        screen_container: document.getElementById("screen_container"),
        bios: { buffer: biosBuf },
        vga_bios: { buffer: vgaBuf },
        bzimage: { buffer: bzimageBuf },
        initrd: { buffer: initrdBuf },
        hda: { buffer: hdaBuf },
        cmdline: "console=ttyS0 rw root=/dev/sda init=/sbin/init tsc=reliable mitigations=off libata.dma=0",
        autostart: true,
        disable_keyboard: true,
        disable_mouse: true,
        disable_speaker: true,
    });

    emulator.add_listener("serial0-output-byte", function(byte) {
        term.write(new Uint8Array([byte]));
    });

    term.onData(function(data) {
        emulator.serial0_send(data);
    });

    emulator.add_listener("emulator-started", function() {
        statusEl.textContent = "running";
    });

    emulator.add_listener("emulator-stopped", function() {
        statusEl.textContent = "stopped";
    });

    term.focus();
};
</script>
</body>
</html>
SCRIPTEND

SIZE=$(du -h "$OUT" | cut -f1)
echo "==> Done: $OUT ($SIZE)"
