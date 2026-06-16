# Ping Pong League — Nuxt frontend (Step 3 scaffold)

Static Nuxt 3 SPA that talks to your Supabase backend. Builds to plain files and
deploys on GitHub Pages. No server of your own to run.

## What's wired up
- **Supabase client** (`plugins/supabase.client.ts`) using the anon public key.
- **Access-code roles** (`composables/useRole.ts`) → calls the `whoami` rpc, keeps
  the code in `localStorage`. UI gating is cosmetic; the DB rpcs re-check the code.
- **Static GitHub Pages build** — `nitro: github_pages` preset emits `404.html`
  (SPA fallback) and `.nojekyll` automatically.
- A working **Leaderboard** page that reads `v_current_standings` (proves the
  connection). Matches / Queue / Tournaments are placeholders until Step 4.

## 1. Local dev
```bash
npm install
cp .env.example .env      # fill in your Supabase URL + anon key
npm run dev               # http://localhost:3000
```

## 2. Point it at your repo
Open `nuxt.config.ts` and set `app.baseURL` to **`/<your-repo-name>/`**
(currently `/pingpong-league/`). If you deploy to a custom domain or to
`username.github.io` root, set it to `/`.

## 3. Deploy to GitHub Pages
1. Create the GitHub repo and push this folder to the `main` branch.
2. Repo **Settings → Pages → Build and deployment → Source: GitHub Actions**.
3. Repo **Settings → Secrets and variables → Actions → Variables tab**, add:
   - `NUXT_PUBLIC_SUPABASE_URL` = your Project URL
   - `NUXT_PUBLIC_SUPABASE_KEY` = your anon public key
   (Variables, not Secrets — the anon key is public by design and must be present
   at build time.)
4. Push to `main`. The workflow in `.github/workflows/deploy.yml` builds and
   publishes. Your site lands at `https://<username>.github.io/<repo>/`.

## Notes
- Only ever use the **anon public** key here. The `service_role` key must never
  touch the frontend.
- If pages 404 on refresh, confirm `baseURL` matches the repo name exactly.
