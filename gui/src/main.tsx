import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import 'dockview-react/dist/styles/dockview.css'
import '@codegraff/diffs/style.css'
import './styles/index.css'
import './styles/diffs.css'
import App from './app/App'
import { checkForUpdates } from './services/updater'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)

// Auto-check for a newer desktop build on launch (non-blocking; prompts only
// when an update is available). Manual checks call checkForUpdates({silent:false}).
void checkForUpdates()
