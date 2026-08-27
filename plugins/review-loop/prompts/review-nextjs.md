---
AGENT 3: Next.js & React Best Practices Review

This is a Next.js project. Review the codebase against these specific patterns:

App Router & Server Components:
- Are Server Components used by default? Is 'use client' only added when interactivity is needed?
- Is data fetched in Server Components, not Client Components?
- Are Suspense boundaries used for streaming slow data sources?
- Are file conventions correct: layout.tsx, page.tsx, loading.tsx, error.tsx, not-found.tsx?
- Are searchParams and params handled as Promises (await searchParams / await params)?
- Is generateStaticParams() used to pre-render known dynamic routes?
- Is generateMetadata() used for SEO-critical pages?
- Is notFound() called for missing resources instead of returning null?

Data Fetching & Caching:
- Are parallel data fetches used (Promise.all) instead of sequential waterfalls?
- Is cache strategy appropriate: no-store for fresh data, force-cache for static, revalidate for ISR?
- Are cache tags used for fine-grained invalidation after mutations?
- Is React.cache() used to deduplicate queries within a single request?

Server Actions & Mutations:
- Are Server Actions validated and auth-checked as if they were public API endpoints?
- Is revalidateTag/revalidatePath called after mutations to invalidate cache?
- Is after() used for non-blocking post-response work (logging, analytics)?

Performance & Bundle Size:
- No barrel file imports — import directly from source paths?
- Is next/dynamic with { ssr: false } used for heavy client-only components?
- Are non-critical libraries (analytics, error tracking) deferred until after hydration?
- Are heavy bundles preloaded on user intent (hover/focus)?
- Is data minimized across the RSC boundary (only pass fields client needs)?

React Performance:
- Is derived state calculated during render, not in effects?
- Are expensive computations memoized appropriately?
- Is useTransition used for non-urgent updates?
- No unnecessary useEffect for things that belong in event handlers?
- Are stable callback references used (functional setState, refs) to avoid re-render churn?
- Is content-visibility: auto used for long lists?
- Are inline scripts used to set client data before hydration (prevent FOUC)?

For each issue: return file path, line number, severity (critical/high/medium/low), category, explanation, and suggested fix.
