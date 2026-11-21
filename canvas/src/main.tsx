import '@fontsource/jetbrains-mono/400.css'
import '@fontsource/space-grotesk/500.css'
import '@fontsource/space-grotesk/700.css'
import '@mantine/core/styles.css'
import '@mantine/notifications/styles.css'
import './app.css'
import './screens/design.css'

import { MantineProvider, createTheme } from '@mantine/core'
import { Notifications } from '@mantine/notifications'
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'

import App from './App'

// SuperX's swindex design system: midnight-purple surfaces, pelican-purple accents, Space Grotesk headings,
// JetBrains Mono code.
const theme = createTheme({
  fontFamily: 'system-ui, -apple-system, Segoe UI, Arial, sans-serif',
  fontFamilyMonospace: "'JetBrains Mono', 'Fira Code', ui-monospace, SFMono-Regular, Menlo, monospace",
  headings: { fontFamily: "'Space Grotesk', system-ui, -apple-system, Segoe UI, sans-serif" },
  primaryColor: 'pelican',
  primaryShade: 5,
  colors: {
    pelican: ['#F6E8FF', '#EBD0FF', '#DDA9FF', '#CC66FF', '#B833E8', '#9500BF', '#8300A8', '#630080', '#4C0063', '#38004A'],
    dark: ['#EDE4F4', '#CFC2DB', '#B0A0C2', '#8F7BA5', '#5C4470', '#3B2449', '#2A1235', '#1F062A', '#150420', '#0E0216'],
  },
})

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <MantineProvider theme={theme} defaultColorScheme="dark">
      <Notifications position="bottom-right" />
      <App />
    </MantineProvider>
  </StrictMode>,
)
