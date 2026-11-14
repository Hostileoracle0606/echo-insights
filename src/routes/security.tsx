import { createFileRoute } from "@tanstack/react-router";

export const Route = createFileRoute("/security")({
  head: () => ({
    meta: [
      { title: "Security and privacy — Lumen" },
      {
        name: "description",
        content: "Who sees what of your Lumen journal, and the controls you have, in plain words.",
      },
    ],
  }),
  component: SecurityPage,
});

// These sentences mirror lib/privacy/privacy_claims.dart (the iOS app's
// "Who hears you" screen); test/privacy_copy_test.dart checks they match. Only
// say here what is true today.
const PARTIES: { name: string; lines: string[] }[] = [
  {
    name: "Google",
    lines: [
      "Lumen sends your voice and text to Google's Gemini service to talk with you.",
      "While you talk, your voice goes to Google live. What Lumen tells Google can also carry things you said in earlier conversations and your opening brief, so earlier journal content goes to Google during a conversation. The text of each turn is sent as you go, to pick out people and places. When a conversation ends, its text goes again to write your cards and briefs and to speak the line Lumen opens with.",
    ],
  },
  {
    name: "Amazon Web Services",
    lines: [
      "Amazon Web Services runs the processing behind Lumen. It handles the text of your conversations while that work happens, and keeps the people, places and notes it pulls out of each turn in a cache for about a week.",
    ],
  },
  {
    name: "Supabase",
    lines: [
      "Supabase stores your journal: your conversations, cards and the map of people and places. It isn't encrypted with a key only you hold, so the people with admin access to the database could technically read it. A written rule limits that access.",
      "The database is set up so that one account can't see another account's journal.",
    ],
  },
  {
    name: "Us",
    lines: [
      "Our rule is that we don't read journals, except for a security incident or a request from you about your own data. Each exception goes in a written log. Nothing technically stops us.",
    ],
  },
  {
    name: "ElevenLabs (web app only)",
    lines: [
      "On the web app, a spoken reply can be voiced by ElevenLabs, which receives the text of that reply. The iPhone app does not use it.",
    ],
  },
  {
    name: "Anyone holding your phone",
    lines: [
      "Anyone who can unlock your phone and open Lumen can read your journal. App lock asks for Face ID or your passcode first. You can turn it on under Privacy.",
    ],
  },
];

const REACH =
  "The companies running these services can in principle reach data on their own systems, and backups can outlive a delete for a limited time.";

const CONTROLS: string[] = [
  "App lock (iPhone): Face ID or your passcode when Lumen opens and after it has been in the background for 5 minutes.",
  'Your journal is yours to take: Privacy has "Export my journal", a zip of your conversations, cards and map as data and as notes.',
  "Export (iPhone) asks for Face ID or your passcode first.",
  "Who hears you (iPhone): the same list as this page, shown on your first conversation and any time under Privacy.",
];

const IPHONE_CONTROLS: string[] = [
  "You can forget a person from their page. They leave your map and the questions Lumen would ask, and their name is replaced in your cards and in what Lumen remembers about others. Mentioning that name later doesn't bring them back. Lumen matches the name they were saved under, so a nickname or a first name alone can slip through. Your saved transcripts keep what you said, and Lumen can still read your past conversations, so it may bring the name up.",
  "Off the record: Lumen doesn't save what you say while it is on, and writes no card from it. Your voice still goes to Google so Lumen can answer.",
  "You can have old transcripts deleted automatically after 7, 30 or 90 days. Cards and what Lumen remembers stay.",
];

function SecurityPage() {
  return (
    <main className="mx-auto max-w-2xl px-4 py-12">
      <h1 className="text-4xl font-display text-foreground">Security and privacy</h1>
      <p className="mt-4 text-base text-muted-foreground">
        Your journal is yours. Here are the services that handle it, what each one sees, and the
        controls you have. This page says only what is true today.
      </p>
      <p className="mt-4 text-base text-foreground">{REACH}</p>

      <h2 className="mt-10 text-2xl font-display text-foreground">Who hears you</h2>
      {PARTIES.map((party) => (
        <section key={party.name} className="mt-6">
          <h3 className="text-lg font-semibold text-foreground">{party.name}</h3>
          {party.lines.map((line) => (
            <p key={line} className="mt-2 text-base text-foreground">
              {line}
            </p>
          ))}
        </section>
      ))}

      <h2 className="mt-10 text-2xl font-display text-foreground">Controls you have</h2>
      <ul className="mt-4 list-disc space-y-2 pl-6 text-base text-foreground">
        {CONTROLS.map((control) => (
          <li key={control}>{control}</li>
        ))}
      </ul>
      <h3 className="mt-6 text-lg font-semibold text-foreground">In the iPhone app</h3>
      <ul className="mt-2 list-disc space-y-2 pl-6 text-base text-foreground">
        {IPHONE_CONTROLS.map((control) => (
          <li key={control}>{control}</li>
        ))}
      </ul>

      <h2 className="mt-10 text-2xl font-display text-foreground">Report a problem</h2>
      <p className="mt-4 text-base text-foreground">
        Found a security problem? Report it privately through our{" "}
        <a
          className="underline"
          href="https://github.com/Hostileoracle0606/echo-insights/security/advisories/new"
        >
          GitHub security advisory form
        </a>
        . The same details are in{" "}
        <a className="underline" href="/.well-known/security.txt">
          security.txt
        </a>
        .
      </p>
    </main>
  );
}
