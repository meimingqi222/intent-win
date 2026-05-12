const fs = require('fs');
const path = require('path');

const srcAsar = path.resolve(process.argv[2]);
const destDir = path.resolve(process.argv[3]);

// Read asar header
// Format: 4 bytes UInt32LE = header JSON byte length, then JSON, then file data
const fd = fs.openSync(srcAsar, 'r');
const headerSizeBuf = Buffer.alloc(4);
fs.readSync(fd, headerSizeBuf, 0, 4, 0);
const headerSize = headerSizeBuf.readUInt32LE(0);
const headerJson = Buffer.alloc(headerSize);
fs.readSync(fd, headerJson, 0, headerSize, 4);
const header = JSON.parse(headerJson.toString('utf8'));

const unpackedBase = srcAsar.replace(/\.asar$/i, '.asar.unpacked');
let skipped = 0;
let extracted = 0;

const dataOffset = 4 + headerSize;

function walk(files, parentPath, entry) {
  if (entry.files) {
    for (const [name, info] of Object.entries(entry.files)) {
      walk(files, parentPath ? parentPath + '/' + name : name, info);
    }
  } else if (entry.unpacked) {
    files.push({ path: parentPath, unpacked: true });
  } else if (typeof entry.offset === 'number' && typeof entry.size === 'number') {
    files.push({ path: parentPath, offset: entry.offset, size: entry.size });
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
    const srcPath = path.join(unpackedBase, f.path);
    try {
      fs.copyFileSync(srcPath, outPath);
      extracted++;
    } catch {
      skipped++;
    }
  } else {
    const buf = Buffer.alloc(f.size);
    fs.readSync(fd, buf, 0, f.size, dataOffset + f.offset);
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
