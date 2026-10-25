import fs;
#{ "def made() -> str { \"" + YCC.target + "\" };" }#
def platform() -> str { if (fs.exists("/")) { "linux" } else { "?" } };
const EXTRA = 7;
