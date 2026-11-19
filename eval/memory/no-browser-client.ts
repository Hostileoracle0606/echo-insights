// Stand-in for src/lib/supabase/browser.ts in the memory eval. Any use is a bug:
// the eval reaches Supabase through its own fetch, as the test user.
export const supabase = new Proxy(
  {},
  {
    get() {
      throw new Error("the browser Supabase client is not available in the memory eval");
    },
  },
);
