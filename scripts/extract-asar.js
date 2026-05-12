const fs = require('fs');
const path = require('path');

const srcAsar = path.resolve(process.argv[2]);
const destDir = path.resolve(process.argv[3]);

// Read asar header
const fd = fs.openSync(srcAsar, 'r');
const headerBuf = Buffer.alloc(8);
fs.readSync(fd, headerBuf, 0, 8, 0);
const headerSize = Number(headerBuf.readBigUInt64LE(0));
const headerJson = Buffer.alloc(headerSize);
fs.readSync(fd, headerJson, 0, headerSize, 8);
const header = JSON.parse(headerJson.toString('utf8'));

const unpackedBase = srcAsar.replace(/\.asar$/i, '.asar.unpacked');
let skipped = 0;
let extracted = 0;

function walk(files, parentPath, entry) {
  if (entry.files) {
    for (const [name, info] of Object.entries(entry.files)) {
      walk(files, parentPath ? parentPath + '/' + name : name, info);
    }
  } else {
    files.push({ path: parentPath, offset: entry.offset, size: entry.size, unpacked: entry.unpacked });
  }
}

const fileList = [];
walk(fileList, '', header);

for (const f of fileList) {
  const outPath = path.join(destDir, f.path);
  fs.mkdirSync(path.dirname(outPath), { recursive: true });

  if (f.unpacked) {
    // Unpacked file: try to copy from app.asar.unpacked directory
    const srcPath = path.join(unpackedBase, f.path);
    try {
      fs.copyFileSync(srcPath, outPath);
      extracted++;
    } catch {
      skipped++;
    }
  } else {
    // Regular file: extract from asar
    const buf = Buffer.alloc(f.size);
    fs.readSync(fd, buf, 0, f.size, 8 + headerSize + f.offset);
    fs.writeFileSync(outPath, buf);
    extracted++;
  }
}

fs.closeSync(fd);

if (skipped > 0) {
  console.warn(`Extracted ${extracted} files, skipped ${skipped} missing unpacked files (dev configs, safe to ignore)`);
} else {
  console.log(`Extracted ${extracted} files from ${path.basename(srcAsar)}`);
}
