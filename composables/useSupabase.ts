import type { SupabaseClient } from '@supabase/supabase-js'

// Convenience accessor so components don't reach for useNuxtApp() directly.
export const useSupabase = (): SupabaseClient => {
  return useNuxtApp().$supabase as SupabaseClient
}
