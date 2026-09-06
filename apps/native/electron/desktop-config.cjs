const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
function desktopConfig(resources, directory) {
  const source = process.env.GRAFF_MCP_CONFIG || path.join(os.homedir(), '.codegraff/mcp.json');
  let config = { mcpServers: {} };
  if (fs.existsSync(source)) {
    config = JSON.parse(fs.readFileSync(source, 'utf8'));
    if (!config.mcpServers || typeof config.mcpServers !== 'object' || Array.isArray(config.mcpServers)) throw new Error('Invalid existing MCP configuration');
  }
  const servers = { ...config.mcpServers, codegraff_desktop: { command: path.join(resources, 'bun'), args: [path.join(resources, 'app/desktop-mcp.cjs')] } };
  // Only the generated desktop config changes. User and workspace files remain intact.
  for (const key of Object.keys(servers)) if (/kuri/i.test(key)) delete servers[key];
  fs.mkdirSync(directory, { recursive: true });
  const destination = path.join(directory, 'desktop-mcp.json');
  fs.writeFileSync(destination, JSON.stringify({ mcpServers: servers }), { mode: 0o600 });
  return destination;
}
module.exports = { desktopConfig };
