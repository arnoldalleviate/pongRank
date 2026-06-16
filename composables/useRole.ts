// Access-code based roles (no logins).
//  - the code is kept in localStorage so officials/commissioner stay "logged in"
//  - the actual role is resolved server-side via the whoami() rpc, never trusted
//    from the client. UI gating is cosmetic; the DB rpcs re-check the code.
import { ref, computed } from 'vue'

type Role = 'viewer' | 'official' | 'commissioner'

const STORAGE_KEY = 'pp_access_code'
const code = ref<string>('')
const role = ref<Role>('viewer')
const resolving = ref(false)

export const useRole = () => {
  const supabase = useSupabase()

  const isOfficial = computed(() => role.value === 'official' || role.value === 'commissioner')
  const isCommissioner = computed(() => role.value === 'commissioner')

  async function resolve() {
    resolving.value = true
    try {
      const { data, error } = await supabase.rpc('whoami', { p_code: code.value || '' })
      role.value = (error ? 'viewer' : (data as Role)) ?? 'viewer'
    } finally {
      resolving.value = false
    }
  }

  // call once on app start (client side)
  function init() {
    if (import.meta.client) {
      code.value = localStorage.getItem(STORAGE_KEY) || ''
      if (code.value) resolve()
    }
  }

  async function setCode(next: string) {
    code.value = next.trim()
    if (import.meta.client) localStorage.setItem(STORAGE_KEY, code.value)
    await resolve()
    return role.value
  }

  function clear() {
    code.value = ''
    role.value = 'viewer'
    if (import.meta.client) localStorage.removeItem(STORAGE_KEY)
  }

  // the code to pass into write rpcs
  const accessCode = computed(() => code.value)

  return { role, isOfficial, isCommissioner, resolving, accessCode, init, setCode, clear, resolve }
}
