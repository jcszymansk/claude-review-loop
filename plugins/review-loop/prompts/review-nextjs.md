---
AGENT 3: Task-Related Next.js & React Review

This is a Next.js project. Apply the SCOPE BOUNDARY from the base prompt. Review only Next.js or React code changed by the current task, or framework behavior directly required for the requested task. Do not report pre-existing framework patterns or general Next.js best-practice gaps outside the task.

App Router & Server Components:
- Are Server Components used by default in the task's changed code? Is 'use client' only added when interactivity is needed?
- Is data fetched in Server Components, not Client Components, where the task changed data fetching?
- Are Suspense boundaries used for streaming slow data sources introduced or changed by this task?
- Are file conventions correct in task-changed routes: layout.tsx, page.tsx, loading.tsx, error.tsx, not-found.tsx?
- Are searchParams and params handled as Promises (await searchParams / await params) in task-changed code?
- Is generateStaticParams() used to pre-render known dynamic routes introduced by this task?
- Is generateMetadata() used for SEO-critical pages changed by this task?
- Is notFound() called for missing resources instead of returning null in task-changed paths?

Data Fetching & Caching:
- Are parallel data fetches used (Promise.all) instead of sequential waterfalls introduced by this task?
- Is cache strategy appropriate for task-changed data fetching: no-store for fresh data, force-cache for static, revalidate for ISR?
- Are cache tags used for fine-grained invalidation after task-changed mutations?
- Is React.cache() used to deduplicate task-changed queries within a single request?

Server Actions & Mutations:
- Are Server Actions changed by this task validated and auth-checked as if they were public API endpoints?
- Is revalidateTag/revalidatePath called after mutations introduced or changed by this task?
- Is after() used for non-blocking post-response work introduced by this task?

Performance & Bundle Size:
- Did the task introduce barrel file imports where direct source imports are needed?
- Did the task introduce an unnecessary heavy client-only bundle?
- Did the task pass unnecessary data across the RSC boundary?

React Performance:
- Is derived state calculated during render, not in effects, in task-changed code?
- Are expensive computations introduced by this task memoized appropriately?
- Is useTransition used for non-urgent task-changed updates?
- Did the task introduce unnecessary useEffect where an event handler is appropriate?
- Are stable callback references used where the task changed state updates?

For each issue: return file path, line number, severity (critical/high/medium/low), category, explanation, and suggested fix. If no task-related Next.js or React issue exists, return no finding for this review path.
