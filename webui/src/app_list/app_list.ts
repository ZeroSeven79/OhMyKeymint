import { exec, getPackagesInfo, listPackages } from 'kernelsu-alt'
import type { PackagesInfo } from 'kernelsu-alt'
import type { Config } from '../config'
import { isValidPackageName } from '../package_name'
import { isDev } from '../utils/dev'

const RECOMMENDED_SYSTEM_APPS = [
  'com.google.android.gsf',
  'com.google.android.gms',
  'com.android.vending',
  // ColorOS "Smart Data Enhancement"; behaves like a Google service for
  // attestation purposes on OPPO/OnePlus/realme builds.
  'com.coloros.sceneservice',
] as const

const PACKAGE_INFO_BATCH_SIZE = 32

const AUTO_PACKAGES_STORAGE_KEY = 'omk-auto-packages'

// Exact identifiers only: a name containing "root" is not evidence that an app
// is a root tool. Permission/category discovery below covers additional apps.
const ROOT_TOOL_PACKAGES = new Set([
  'me.weishu.kernelsu',
  'com.rifsxd.ksunext',
  'me.bmax.apatch',
  'com.topjohnwu.magisk',
  'io.github.huskydg.magisk',
  'eu.chainfire.supersu',
  'com.noshufou.android.su',
  'org.lsposed.manager',
  'de.robv.android.xposed.installer',
  'org.meowcat.edxposed.manager',
  'moe.shizuku.privileged.api',
  'rikka.sui',
  'com.tsng.hidemyapplist',
  'org.frknkrc44.hma_oss',
  'bin.mt.plus',
])

/** User-maintained additions, shared with the background helper script. */
const AUTO_EXCLUDE_FILE = '/data/adb/omk/autoscoop.exclude'

// The permission scan that powers the recommended selection can fail on some
// devices (dumpsys timeouts are common). Remember what it found so the
// automatic sync can still skip those apps on a later run instead of silently
// falling back to the static list only.
const RECOMMENDED_EXCLUDE_CACHE_KEY = 'omk-recommended-exclude'

// System apps the user ticked explicitly through "Add System App". Kept out of
// the automatic set's reach so a later refresh cannot undo them.
const USER_SYSTEM_APPS_KEY = 'omk-user-system-apps'

/**
 * Last automatic result, paired with a fingerprint of the installed set.
 *
 * Re-toggling the switch with nothing installed or removed used to recompute
 * the set from scratch, and the two runs could disagree by a package because the
 * enumeration or the permission scan resolved differently. Reusing the stored
 * result while the fingerprint is unchanged makes the switch idempotent.
 */
const AUTO_STATE_FILE = '/data/adb/omk/autoscoop.state'

/** Order-independent fingerprint of a package name list. */
function fingerprintOf(names: readonly string[]): string {
  let hash = 5381
  const joined = [...names].sort().join('\n')
  for (let index = 0; index < joined.length; index += 1) {
    hash = ((hash << 5) + hash + joined.charCodeAt(index)) | 0
  }
  return `${(hash >>> 0).toString(36)}-${names.length}`
}

interface AutoState {
  fingerprint: string
  merged: string[]
}

async function readAutoState(): Promise<AutoState | null> {
  try {
    const result = await exec(`/system/bin/sh -c 'cat ${AUTO_STATE_FILE} 2>/dev/null'`)
    if (result.errno !== 0) return null
    const lines = result.stdout.split(/\r?\n/).map(line => line.trim()).filter(line => line !== '')
    if (lines.length < 1) return null
    const [fingerprint, ...merged] = lines
    if (fingerprint === undefined) return null
    return { fingerprint, merged: merged.filter(isValidPackageName) }
  } catch {
    return null
  }
}

async function writeAutoState(fingerprint: string, merged: readonly string[]): Promise<void> {
  if (fingerprint === '' || merged.length === 0) return
  try {
    // Package names match [A-Za-z0-9_.] so they need no shell quoting here.
    const body = [fingerprint, ...merged].join(' ')
    await exec(
      `/system/bin/sh -c 'mkdir -p /data/adb/omk 2>/dev/null; printf "%s\\n" ${body} > ${AUTO_STATE_FILE}'`,
    )
  } catch {
    // Best effort: without it the next toggle simply recomputes.
  }
}

function readStoredList(key: string): string[] {
  try {
    const stored = window.localStorage.getItem(key)
    if (stored === null) return []
    const parsed: unknown = JSON.parse(stored)
    if (!Array.isArray(parsed)) return []
    return parsed.filter(isValidPackageName)
  } catch {
    return []
  }
}

function writeStoredList(key: string, values: readonly string[]): void {
  try {
    window.localStorage.setItem(key, JSON.stringify(values))
  } catch {
    // Persistence is a refinement; the in-memory result stays correct.
  }
}

async function readUserExclusions(): Promise<string[]> {
  try {
    const result = await exec(`/system/bin/sh -c 'cat ${AUTO_EXCLUDE_FILE} 2>/dev/null'`)
    if (result.errno !== 0) return []
    return result.stdout
      .split(/\r?\n/)
      .map(line => line.trim())
      .filter(isValidPackageName)
  } catch {
    return []
  }
}

/**
 * Persist the permission scan's findings into the same exclude file the user
 * edits by hand.
 *
 * A file is used rather than localStorage because the scan is not guaranteed to
 * succeed on every launch: `dumpsys` times out on busy devices. Without a
 * durable copy, a failed scan would fall back to the static list only and the
 * automatic sync would start adding root tools that the recommended selection
 * skips. The background helper script reads this file too, so both agree.
 */
async function persistDiscoveredExclusions(names: readonly string[]): Promise<void> {
  if (names.length === 0) return
  try {
    const existing = new Set(await readUserExclusions())
    const merged = [...existing, ...names.filter(name => !existing.has(name))]
    // Package names match [A-Za-z0-9_.] so they need no shell quoting here.
    const list = merged.join(' ')
    await exec(`/system/bin/sh -c 'mkdir -p /data/adb/omk 2>/dev/null; printf "%s\\n" ${list} > ${AUTO_EXCLUDE_FILE}'`)
  } catch {
    // Best effort: the in-memory result for this run is still correct.
  }
}

function afterPaint(): Promise<void> {
  return new Promise(resolve => {
    window.requestAnimationFrame(() => window.setTimeout(resolve, 0))
  })
}

function normalizeSearchQuery(query: string): string {
  return query.trim().toLocaleLowerCase()
}

async function queryInstalledPackages(type: 'all' | 'user' | 'system' = 'all'): Promise<string[]> {
  // ksu.listPackages() can retain the package-manager snapshot from the
  // WebView process. Query Android's package manager directly on every fetch
  // so apps installed while the WebUI is open appear without a cold start.
  const filter = type === 'user' ? ' -3' : type === 'system' ? ' -s' : ''
  const commands = [
    `/system/bin/pm list packages --user 0${filter}`,
    `cmd package list packages --user 0${filter}`,
  ]
  for (const command of commands) {
    try {
      const result = await exec(command)
      if (result.errno !== 0) continue
      const packages = result.stdout
        .split(/\r?\n/)
        .map(line => line.trim())
        .filter(line => line.startsWith('package:'))
        .map(line => line.slice('package:'.length))
        .filter(isValidPackageName)
      if (packages.length > 0 || result.stdout.trim() === '') return [...new Set(packages)].sort()
    } catch {
      // Try the alternate package-manager command before using the bridge.
    }
  }

  // Keep compatibility with older KernelSU/APatch WebUI bridges that do not
  // expose exec but do provide listPackages.
  return listPackages(type)
}

export type SelectionFilter = 'all' | 'selected' | 'unselected'

export interface AppEntry {
  packageName: string
  appName: string
  isSystem: boolean
}

export interface SelectableAppEntry extends AppEntry {
  selected: boolean
}

export interface AppListSnapshot {
  revision: number
  entries: readonly AppEntry[]
  selectedPackages: readonly string[]
  selectedCount: number
  isWritable: boolean
}

export type AppListSubscriber = (snapshot: AppListSnapshot) => void

export class AppList {
  readonly #config: Config
  readonly #packageInfoCache = new Map<string, PackagesInfo>()
  readonly #subscribers = new Set<AppListSubscriber>()
  #entries: AppEntry[] = []
  #revision = 0
  #fetchPromise: Promise<boolean> | null = null
  #recommendedPackages: Promise<ReadonlySet<string>> | null = null
  #lastRecommended: ReadonlySet<string> | null = null

  constructor(config: Config) {
    this.#config = config
  }

  get revision(): number {
    return this.#revision
  }

  get isWritable(): boolean {
    return this.#config.isWritable
  }

  getSnapshot(): AppListSnapshot {
    const selectedPackages = [...new Set(this.#config.get('target'))]
    return {
      revision: this.#revision,
      entries: [...this.#entries],
      selectedPackages,
      selectedCount: selectedPackages.length,
      isWritable: this.#config.isWritable,
    }
  }

  subscribe(subscriber: AppListSubscriber): () => void {
    this.#subscribers.add(subscriber)
    subscriber(this.getSnapshot())
    return () => this.#subscribers.delete(subscriber)
  }

  async fetch(): Promise<boolean> {
    if (this.#fetchPromise !== null) return this.#fetchPromise
    const request = this.#fetch()
    this.#fetchPromise = request
    try {
      return await request
    } finally {
      if (this.#fetchPromise === request) this.#fetchPromise = null
    }
  }

  getEntries(): readonly AppEntry[] {
    return [...this.#entries]
  }

  getTargetEntries(query = '', filter: SelectionFilter = 'all'): SelectableAppEntry[] {
    const selected = new Set(this.#config.get('target'))
    const normalizedQuery = normalizeSearchQuery(query)
    return this.#entries
      .filter(entry => !entry.isSystem)
      .map(entry => ({ ...entry, selected: selected.has(entry.packageName) }))
      .filter(entry => this.#matches(entry, normalizedQuery, filter))
      .sort((left, right) => this.#compareEntries(left, right))
  }

  getSystemEntries(query = ''): SelectableAppEntry[] {
    const selected = new Set(this.#config.get('target'))
    const normalizedQuery = normalizeSearchQuery(query)
    return this.#entries
      .filter(entry => entry.isSystem)
      .map(entry => ({ ...entry, selected: selected.has(entry.packageName) }))
      .filter(entry => this.#matchesSearch(entry, normalizedQuery))
      .sort((left, right) => this.#compareEntries(left, right))
  }

  getSelectedPackages(): string[] {
    return [...new Set(this.#config.get('target'))]
  }

  getSelectedCount(): number {
    return this.getSelectedPackages().length
  }

  isSelected(packageName: string): boolean {
    return this.#config.get('target').includes(packageName)
  }

  setSelected(packageName: string, selected: boolean): void {
    if (!isValidPackageName(packageName)) return
    const targets = new Set(this.#config.get('target'))
    const changed = selected ? !targets.has(packageName) : targets.has(packageName)
    if (!changed) return

    if (selected) targets.add(packageName)
    else targets.delete(packageName)
    this.#config.set('target', [...targets])
    this.#emitChange()
  }

  toggleSelected(packageName: string): void {
    this.setSelected(packageName, !this.isSelected(packageName))
  }

  async selectRecommended(): Promise<void> {
    // Discover only on explicit selection, once per package-list refresh. Never
    // scan every installed package or issue one Binder request per app.
    const recommended = await this.#getRecommendedPackages()
    const targets = new Set(this.#config.get('target'))
    let changed = false
    for (const entry of this.#entries) {
      if (!recommended.has(entry.packageName)) continue
      if (targets.has(entry.packageName)) continue
      targets.add(entry.packageName)
      changed = true
    }
    if (!changed) return
    this.#config.set('target', [...targets])
    this.#emitChange()
  }

  deselectAll(): void {
    if (this.#config.get('target').length === 0) return
    this.#config.set('target', [])
    this.#emitChange()
  }

  /**
   * Align `target` with the set of user-installed apps and persist it.
   *
   * Follows the recommended selection exactly: a package that "Select
   * recommended" would skip is never added here either. The two paths share one
   * computed set, so root tools, Shizuku/Xposed clients and any app that the
   * permission scan flags are excluded identically, and no system package other
   * than the recommended ones is ever added.
   *
   * Runs through the WebUI package bridge and `Config.write()`, the same path a
   * manual selection uses, so it does not depend on any background helper being
   * alive. Package names the automatic refresh wrote previously are tracked in
   * local storage; everything else stays untouched because the user selected it
   * by hand.
   *
   * Returns the resulting package count, or `null` when nothing changed.
   */
  async syncFromInstalled(): Promise<number | null> {
    if (isDev()) return null
    await this.fetch()

    const previousAuto = new Set<string>(this.#readAutoLedger())
    // Anything the user put here by hand survives, plus whatever they ticked
    // through "Add System App" - the automatic set must never undo those.
    const userSystemApps = new Set(readStoredList(USER_SYSTEM_APPS_KEY))

    // Nothing has been installed or removed since the last run, so reuse that
    // result instead of recomputing. The two computations can disagree by a
    // package - the enumeration and the permission scan are both allowed to
    // resolve differently between runs - which made re-toggling the switch
    // report a different count each time.
    const fingerprint = fingerprintOf(this.#entries.map(entry => entry.packageName))
    const stored = await readAutoState()
    if (stored !== null && stored.fingerprint === fingerprint && stored.merged.length > 0) {
      const reused = [...new Set([...stored.merged, ...userSystemApps])].sort()
      const current = this.#config.get('target')
      if (reused.length === current.length
          && reused.every((name, index) => current[index] === name)) {
        return null
      }
      this.#config.set('target', reused)
      this.#emitChange()
      await this.save()
      return reused.length
    }

    const manual = this.#config.get('target').filter(name => !previousAuto.has(name))

    const userExcluded = new Set(await readUserExclusions())
    let auto: string[]
    try {
      const recommended = await this.#resolveRecommendedPackages()
      auto = this.#entries
        .filter(entry => recommended.has(entry.packageName) && !userExcluded.has(entry.packageName))
        .map(entry => entry.packageName)
    } catch {
      // Classification is unavailable, so the automatic set cannot be trusted.
      // Reuse the static list plus every persisted finding; the file-backed
      // entries are what a previous successful scan recorded.
      const excluded = new Set([
        ...ROOT_TOOL_PACKAGES,
        ...readStoredList(RECOMMENDED_EXCLUDE_CACHE_KEY),
        ...userExcluded,
      ])
      const recommendedSystem = new Set<string>(RECOMMENDED_SYSTEM_APPS)
      auto = this.#entries
        .filter(entry => (!entry.isSystem || recommendedSystem.has(entry.packageName))
          && !excluded.has(entry.packageName))
        .map(entry => entry.packageName)
    }

    if (auto.length === 0) return null
    this.#writeAutoLedger(auto)

    const merged = [...new Set([...manual, ...auto, ...userSystemApps])].sort()
    if (merged.length === this.#config.get('target').length
        && merged.every((name, index) => this.#config.get('target')[index] === name)) {
      await writeAutoState(fingerprint, merged)
      return null
    }

    this.#config.set('target', merged)
    this.#emitChange()
    await this.save()
    await writeAutoState(fingerprint, merged)
    return merged.length
  }

  #readAutoLedger(): string[] {
    try {
      const stored = window.localStorage.getItem(AUTO_PACKAGES_STORAGE_KEY)
      if (stored === null) return []
      const parsed: unknown = JSON.parse(stored)
      if (!Array.isArray(parsed)) return []
      return parsed.filter(isValidPackageName)
    } catch {
      return []
    }
  }

  #writeAutoLedger(packages: readonly string[]): void {
    try {
      window.localStorage.setItem(AUTO_PACKAGES_STORAGE_KEY, JSON.stringify(packages))
    } catch {
      // The ledger only refines manual-vs-automatic bookkeeping; losing it is
      // not fatal because the merged list stays correct either way.
    }
  }

  applySystemAppSelection(checkedApps: readonly string[]): void {
    const installedSystemApps = new Set(
      this.#entries.filter(entry => entry.isSystem).map(entry => entry.packageName),
    )
    const checked = new Set(
      checkedApps.filter(packageName => (
        isValidPackageName(packageName) && installedSystemApps.has(packageName)
      )),
    )

    const targets = new Set(this.#config.get('target'))
    for (const packageName of installedSystemApps) {
      if (checked.has(packageName)) targets.add(packageName)
      else targets.delete(packageName)
    }
    // Remember the explicit choice so the automatic sync never removes it.
    writeStoredList(USER_SYSTEM_APPS_KEY, [...checked])
    this.#config.set('target', [...targets])
    this.#emitChange()
  }

  async save(): Promise<void> {
    await this.#config.write()
  }

  async #fetch(): Promise<boolean> {
    this.#recommendedPackages = null
    if (isDev()) return this.#replaceEntries(this.#getDevEntries())

    // KernelSU package APIs cross a synchronous WebView bridge. Yield before
    // each call so the navigation and progress animations can reach the screen.
    await afterPaint()
    const packages = await queryInstalledPackages()
    await afterPaint()
    const systemPackages = new Set(await queryInstalledPackages('system'))
    const installedPackages = new Set(packages)

    for (const packageName of this.#packageInfoCache.keys()) {
      if (!installedPackages.has(packageName)) this.#packageInfoCache.delete(packageName)
    }

    const missingPackages = packages.filter(packageName => !this.#packageInfoCache.has(packageName))
    for (let offset = 0; offset < missingPackages.length; offset += PACKAGE_INFO_BATCH_SIZE) {
      await afterPaint()
      const batch = missingPackages.slice(offset, offset + PACKAGE_INFO_BATCH_SIZE)
      try {
        const infos = await getPackagesInfo(batch) as PackagesInfo[]
        for (const info of infos) {
          if (isValidPackageName(info.packageName) && installedPackages.has(info.packageName)) {
            this.#packageInfoCache.set(info.packageName, info)
          }
        }
      } catch {
        // Package names remain selectable when labels or metadata are unavailable.
      }
    }

    return this.#replaceEntries(packages.map(packageName => {
      const info = this.#packageInfoCache.get(packageName)
      return {
        packageName,
        appName: typeof info?.appLabel === 'string' && info.appLabel
          ? info.appLabel
          : packageName,
        // Labels can be absent from the WebView bridge, especially for overlays.
        // PackageManager classification remains available independently.
        isSystem: systemPackages.has(packageName) || info?.isSystem === true,
      }
    }))
  }

  /**
   * Recommended packages, computed once per list refresh and shared by both the
   * manual "select recommended" action and the automatic sync. Sharing the cache
   * keeps the two paths identical instead of drifting apart.
   */
  async #getRecommendedPackages(): Promise<ReadonlySet<string>> {
    this.#recommendedPackages ??= this.#queryRecommendedPackages().catch(error => {
      this.#recommendedPackages = null
      throw error
    })
    return this.#recommendedPackages
  }

  async #resolveRecommendedPackages(): Promise<ReadonlySet<string>> {
    try {
      const recommended = await this.#getRecommendedPackages()
      // Remember a good result for this session: a later refresh whose probes
      // time out can then reuse it instead of degrading the automatic sync.
      this.#lastRecommended = recommended
      return recommended
    } catch (error) {
      if (this.#lastRecommended !== null) return this.#lastRecommended
      throw error
    }
  }

  #isScanFailure(result: { errno: number, stdout: string, stderr: string }): boolean {
    return result.errno !== 0
      || /permission denial|unknown command|can't find service|error:|securityexception|dump timed out/i
        .test(`${result.stdout}\n${result.stderr}`)
  }

  #collectScannedPackages(stdout: string, excluded: Set<string>): void {
    for (const line of stdout.split(/\r?\n/)) {
      const packageName = line.match(/^\s*Package \[([^\]]+)\]/)?.[1]
        ?? line.trim().match(/^([A-Za-z][A-Za-z0-9_.]*)\//)?.[1]
      if (packageName && isValidPackageName(packageName)) excluded.add(packageName)
    }
  }

  async #queryRecommendedPackages(): Promise<ReadonlySet<string>> {
    const excluded = new Set(ROOT_TOOL_PACKAGES)
    let userPackages: string[]
    if (isDev()) {
      userPackages = this.#entries.filter(entry => !entry.isSystem).map(entry => entry.packageName)
    } else {
      await afterPaint()
      userPackages = await queryInstalledPackages('user')
      // PackageManager limits this dump to users of these declared permissions;
      // it does not request the full installed-app dump or inspect private data.
      const commands = [
        'dumpsys -t 8 package permission moe.shizuku.manager.permission.API_V23 moe.shizuku.manager.permission.API android.permission.ACCESS_SUPERUSER com.topjohnwu.magisk.permission.REQUEST_SU',
        'cmd package query-activities --brief --components --user 0 -a android.intent.action.MAIN -c de.robv.android.xposed.category.MODULE_SETTINGS',
      ]
      // Track whether any probe answered at all. "Answered but found nothing"
      // is a valid result and must not be treated as a failure.
      let scanAnswered = false
      for (const command of commands) {
        await afterPaint()
        const result = await exec(command)
        if (this.#isScanFailure(result)) continue
        scanAnswered = true
        this.#collectScannedPackages(result.stdout, excluded)
      }

      const cached = readStoredList(RECOMMENDED_EXCLUDE_CACHE_KEY)
      if (scanAnswered) {
        // Persist the fresh findings so a later run that cannot reach
        // PackageManager still skips the same apps.
        const discovered = [...excluded].filter(name => !ROOT_TOOL_PACKAGES.has(name))
        if (discovered.length > 0) {
          writeStoredList(RECOMMENDED_EXCLUDE_CACHE_KEY, discovered)
          await persistDiscoveredExclusions(discovered)
        }
      } else if (cached.length > 0) {
        // Reuse the previous findings rather than silently selecting root tools
        // just because one probe timed out.
        for (const name of cached) excluded.add(name)
      } else {
        throw new Error('Unable to identify app permissions for recommended selection')
      }
    }
    return new Set([
      ...userPackages.filter(packageName => !excluded.has(packageName)),
      ...RECOMMENDED_SYSTEM_APPS,
    ])
  }

  #replaceEntries(entries: AppEntry[]): boolean {
    const previousEntries = new Map(this.#entries.map(entry => [entry.packageName, entry]))
    const changed = entries.length !== this.#entries.length || entries.some(entry => {
      const previous = previousEntries.get(entry.packageName)
      return previous?.appName !== entry.appName || previous.isSystem !== entry.isSystem
    })
    if (!changed) return false

    this.#entries = entries
    this.#emitChange()
    return true
  }

  #matches(
    entry: SelectableAppEntry,
    normalizedQuery: string,
    filter: SelectionFilter,
  ): boolean {
    const selectionMatches = filter === 'all'
      || (filter === 'selected' && entry.selected)
      || (filter === 'unselected' && !entry.selected)
    return selectionMatches && this.#matchesSearch(entry, normalizedQuery)
  }

  #matchesSearch(entry: AppEntry, normalizedQuery: string): boolean {
    if (!normalizedQuery) return true
    return `${entry.appName}\n${entry.packageName}`.toLocaleLowerCase().includes(normalizedQuery)
  }

  #compareEntries(left: SelectableAppEntry, right: SelectableAppEntry): number {
    if (left.selected !== right.selected) return left.selected ? -1 : 1
    return left.appName.localeCompare(right.appName)
  }

  #emitChange(): void {
    this.#revision++
    const snapshot = this.getSnapshot()
    for (const subscriber of this.#subscribers) subscriber(snapshot)
  }

  #getDevEntries(): AppEntry[] {
    return [
      { packageName: 'io.github.vvb2060.keyattestation', appName: 'Key Attestation', isSystem: false },
      { packageName: 'com.example.app', appName: 'Example App', isSystem: false },
      { packageName: 'com.example.banking', appName: 'Banking App', isSystem: false },
      { packageName: 'com.google.android.gms', appName: 'Google Play services', isSystem: true },
      { packageName: 'com.android.vending', appName: 'Google Play Store', isSystem: true },
      { packageName: 'com.google.android.gsf', appName: 'Google Services Framework', isSystem: true },
    ]
  }
}
