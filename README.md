# Shape Sentinel – Prospective Memory Experiment

A neutral browser-based shape identification task with low- and high-distraction trials, consent and practice flow, F/J/K identification responses, and the additional 1 response for blue triangles. Reaction times are stored in seconds to three decimal places.

## Supabase setup

1. Create a Supabase project.
2. In the Supabase Dashboard, open **SQL Editor**, create a query, paste the contents of [`supabase/setup.sql`](supabase/setup.sql), and run it once. It creates the summary, private contacts, and trial tables plus a validated submission function.
3. The site sends completed sessions to the Supabase RPC endpoint using the public publishable key. Tables have RLS enabled and direct table access is revoked for public roles. Never put a Supabase secret/service-role key in the website.

## Deploy

The repository can be imported into Vercel as a static site; it serves `index.html` from the repository root. A new GitHub push triggers a redeploy when Git integration is enabled.

## Download study data

After collection, run the three export queries at the bottom of `supabase/setup.sql` in the Supabase SQL Editor. Download query results as CSV. The participant summary joins email from the separate contacts table; the trial-level export contains participant IDs but no email. The page also offers CSV downloads for a single participant session.
