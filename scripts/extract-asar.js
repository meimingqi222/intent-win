const { getRawHeader, extractFile, listPackage } = require('@electron/asar');
const fs = require('fs');
const path = require('path');

const srcAsar = path.resolve(process.argv[2]);
const destDir = path.resolve(process.argv[3]);

fs.mkdirSync(destDir, { recursive: true });

const unpackedBase = srcAsar.replace(/\.asar$/i, '.asar.unpacked');
let skipped = 0;
let extracted = 0;
const errors = [];

// Get all files in the asar
const files = listPackage(srcAsar);

for (const filePath of files) {
  // Strip leading separators to make path relative
  const relativePath = filePath.replace(/^[/\\]+/, '');
  const outPath = path.join(destDir, relativePath);

  try {
    // Try to extract from asar (works for non-unpacked files)
    const content = extractFile(srcAsar, filePath);
    fs.mkdirSync(path.dirname(outPath), { recursive: true });
    fs.writeFileSync(outPath, content);
    extracted++;
  } catch (extractErr) {
    // File might be unpacked (stored outside asar)
    const srcPath = path.join(unpackedBase, relativePath);
    try {
      fs.mkdirSync(path.dirname(outPath), { recursive: true });
      fs.copyFileSync(srcPath, outPath);
      extracted++;
    } catch (copyErr) {
      // File is neither in asar nor in unpacked dir — skip
      skipped++;
      if (errors.length < 10) {
        errors.push(filePath);
      }
    }
  }
}

if (errors.length > 0) {
  console.warn(`Extracted ${extracted} files, skipped ${skipped} missing files (dev configs):`);
  for (const e of errors) {
    console.warn(`  - ${e}`);
  }
  if (skipped > errors.length) {
    console.warn(`  ... and ${skipped - errors.length} more`);
  }
} else {
  console.log(`Extracted ${extracted} files from ${path.basename(srcAsar)}`);
}
