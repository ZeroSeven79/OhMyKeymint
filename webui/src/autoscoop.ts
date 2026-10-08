import { exec } from 'kernelsu-alt'

const MODULE_ROOT = '/data/adb/modules/oh_my_keymint'
const HELPER = `${MODULE_ROOT}/autoscoop.sh`

export interface AutomationState {
  autoApps: boolean
}

const DEFAULT_STATE: AutomationState = {
  autoApps: false,
}

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'\\''`)}'`
}

function parseState(output: string): AutomationState {
  const values: Record<string, string> = {}
  for (const line of output.split(/\r?\n/)) {
    const match = /^([a-z_]+)=(.*)$/.exec(line.trim())
    if (match !== null) values[match[1]] = match[2]
  }
  return {
    autoApps: values.auto_apps === '1',
  }
}

async function run(command: string): Promise<string> {
  const result = await exec(`/system/bin/sh -c ${shellQuote(command)}`)
  if (result.errno !== 0) {
    throw new Error(result.stderr.trim() || `autoscoop exited with code ${result.errno}`)
  }
  return result.stdout.trim()
}

export async function readAutomationState(): Promise<AutomationState> {
  try {
    return parseState(await run(`${HELPER} get`))
  } catch {
    return { ...DEFAULT_STATE }
  }
}

export async function writeAutomationState(
  patch: Partial<Pick<AutomationState, 'autoApps'>>,
): Promise<AutomationState> {
  const assignments: string[] = []
  if (patch.autoApps !== undefined) assignments.push(`auto_apps=${patch.autoApps ? 1 : 0}`)
  if (assignments.length === 0) return readAutomationState()
  return parseState(await run(`${HELPER} set ${assignments.join(' ')}`))
}

/** Returns the number of package names now present in scoop. */
export async function syncPackagesNow(): Promise<number> {
  const output = await run(`${HELPER} sync-packages`)
  const count = Number(output.split(/\s+/)[1])
  if (!output.startsWith('ok')) throw new Error('Automatic package refresh did not complete')
  return Number.isFinite(count) ? count : 0
}

export async function disableAutoPackages(): Promise<void> {
  await run(`${HELPER} disable-packages`)
}

/** Diagnostic dump used to explain why an automatic refresh did nothing. */
export async function readDiagnostics(): Promise<string> {
  try {
    return await run(`${HELPER} status`)
  } catch (error) {
    return `unavailable: ${error instanceof Error ? error.message : String(error)}`
  }
}

/**
 * Make sure the background daemon is alive. Called whenever the WebUI opens so
 * the automation recovers even if service.sh could not start it at boot.
 */
export async function ensureDaemon(): Promise<string> {
  try {
    return await run(`${HELPER} ensure`)
  } catch (error) {
    return `error: ${error instanceof Error ? error.message : String(error)}`
  }
}
