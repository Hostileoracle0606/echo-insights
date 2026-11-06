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
// "Who hears you" screen); test/privacy_copy_test.dart checks the Google line
// matches. Only say here what is true today.
const PARTIES: { name: string; lines: string[] }[] = [
  {
    name: "Google",
    lines: [
      "Lumen sends your voice and text to Google's Gemini service to talk with you.",
      "Your voice goes live while you talk. Afterwards the text of what was said goes too, to pick out people and places, to write your cards and briefs, and to speak the line Lumen opens with.",
    ],
  },
  {
    name: "Amazon Web Services",
    lines: [
      "Amazon Web Services runs the processing behind Lumen. It handles the text of your conversations briefly while that work happens.",
    ],
  },
  {
    name: "Supabase",
    lines: [
      "Supabase stores your journal: your conversations, cards and the map of people and places. It isn't encrypted with a key only you hold, so the people with admin access to the database could technically read it. A written rule limits that access.",
      "The database keeps each account's rows from other accounts.",
    ],
  },
  {
    name: "Us",
    lines: [
      "Our rule is that we don't read journals, except for a security incident or a request from you about your own data. Each exception goes in a written log. Nothing technically stops us yet.",
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
      "Anyone who can unlock your phone and open Lumen can read your journal. In the iPhone app, App lock asks for Face ID or your passcode first. You can turn it on under Privacy.",
    ],
  },
];

const CONTROLS: string[] = [
  "App lock (iPhone): Face ID or your passcode when Lumen opens and after it has been in the background for 5 minutes.",
  'Your journal is yours to take: Privacy has "Export my journal", a zip of your conversations, cards and map as data and as notes.',
  "Export (iPhone) asks for Face ID or your passcode first.",
  "Who hears you (iPhone): the same list as this page, shown on your first conversation and any time under Privacy.",
];

function SecurityPage() {
  return (
    <main className="mx-auto max-w-2xl px-4 py-12">
      <h1 className="text-4xl font-display text-foreground">Security and privacy</h1>
      <p className="mt-4 text-base text-muted-foreground">
        Your journal is yours. Here is everyone who sees any of it, what they see, and the controls
        you have. This page says only what is true today.
      </p>

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
