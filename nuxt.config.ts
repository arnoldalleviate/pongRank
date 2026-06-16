// https://nuxt.com/docs/api/configuration/nuxt-config
//
// Static SPA build for GitHub Pages.
//  - ssr: false  -> single-page app (no server needed; perfect for Pages)
//  - nitro github_pages preset -> auto-creates 404.html SPA fallback + .nojekyll
//  - app.baseURL -> site is served from username.github.io/<REPO>, so assets
//    must be prefixed. CHANGE '/pingpong-league/' BELOW if your repo differs.
//    (If you deploy to a custom domain or username.github.io root, set '/'.)

export default defineNuxtConfig({
  compatibilityDate: '2025-01-01',
  devtools: { enabled: false },
  ssr: false,

  // Nuxt 3.21.8's vite-builder throws "No entry found in rollupOptions.input"
  // on `ssr:false` dev unless the Vite Environment API path is used. This flag
  // selects that path (see vite-builder dist line ~277/280).
  experimental: {
    viteEnvironmentApi: true,
    // 3.21.8 can't resolve the #app-manifest virtual in dev under the
    // Environment API path. This app uses no route rules / payload, so
    // disabling the manifest drops the bad import with nothing lost.
    appManifest: false,
  },

  nitro: {
    preset: 'github_pages',
  },

  app: {
    // >>> THE ONE PLACE TO CHANGE FOR YOUR REPO NAME <<<
    baseURL: '/pongRank/',
    head: {
      title: 'Ping League',
      meta: [
        { charset: 'utf-8' },
        { name: 'viewport', content: 'width=device-width, initial-scale=1' },
        { name: 'theme-color', content: '#0A1A33' },
      ],
      link: [
        {
          // brand mark: overlapping blue + yellow circles, on the navy arena
          rel: 'icon',
          type: 'image/svg+xml',
          href: "data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'><rect width='64' height='64' rx='14' fill='%230A1A33'/><circle cx='26' cy='32' r='15' fill='%232F6FED'/><circle cx='38' cy='32' r='15' fill='%23FFCB2D'/></svg>",
        },
        { rel: 'preconnect', href: 'https://fonts.googleapis.com' },
        { rel: 'preconnect', href: 'https://fonts.gstatic.com', crossorigin: '' },
        {
          rel: 'stylesheet',
          href: 'https://fonts.googleapis.com/css2?family=Anton&family=Inter:wght@400;500;600;700&family=Spline+Sans+Mono:wght@500;600&display=swap',
        },
      ],
    },
  },

  css: ['~/assets/css/main.css'],

  // Public runtime config is baked at build time for static SPA.
  // Provide these via env (NUXT_PUBLIC_*) locally and in CI.
  runtimeConfig: {
    public: {
      supabaseUrl: '',   // <- NUXT_PUBLIC_SUPABASE_URL
      supabaseKey: '',   // <- NUXT_PUBLIC_SUPABASE_KEY (anon public key ONLY)
    },
  },
})
