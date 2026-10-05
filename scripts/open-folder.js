const { execFile } = require("child_process");
const path = require("path");

const target = path.resolve(process.argv[2] || ".");

const opener =
  process.platform === "win32" ? "explorer.exe" : process.platform === "darwin" ? "open" : "xdg-open";

// explorer.exe on Windows commonly exits non-zero even when it opens the
// folder fine, so this never fails the npm script chain it's appended to.
execFile(opener, [target], () => {});
