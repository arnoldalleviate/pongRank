// Creates a single Supabase client and provides it app-wide as $supabase.
// Client-only: this is a static SPA, all data access happens in the browser
// using the anon public key (writes are blocked by RLS and only allowed
// through the SECURITY DEFINER rpcs that check an access code).
import { createClient } from '@supabase/supabase-js'

export default defineNuxtPlugin(() => {
  const config = useRuntimeConfig()
  const url = config.public.supabaseUrl as string
  const key = config.public.supabaseKey as string

  if (!url || !key) {
    // Surfaces a clear message if env wasn't provided at build time.
    console.error(
      '[supabase] Missing NUXT_PUBLIC_SUPABASE_URL / NUXT_PUBLIC_SUPABASE_KEY. ' +
      'Set them in .env (dev) and as CI variables (deploy).'
    )
  }

  const supabase = createClient(url, key, {
    auth: { persistSession: false },           // no logins in this app
    realtime: { params: { eventsPerSecond: 10 } },
  })

  return { provide: { supabase } }
})
