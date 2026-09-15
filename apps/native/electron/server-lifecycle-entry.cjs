// Exercise the production detached backend group; the launcher owns cleanup.
delete process.env.GRAFF_TEST_MANAGED_GROUP;
const logs = require('node:path').join(process.env.GRAFF_SHUTDOWN_OUTPUT, 'logs');
require('node:fs').mkdirSync(logs, {recursive:true});
require('electron').app.setPath('logs', logs);
require('./main.cjs');
