import assert from "node:assert/strict";
import { test } from "node:test";

import { createEmailService, resolveEmailDriver } from "./email.ts";
import {
  readSmtpConfig,
  resolveSmtpHostIpv4,
  type SmtpTransport,
} from "./smtp-email.ts";
import type { TransactionalEmailMessage } from "./email.ts";

const SMTP_ENV = {
  EMAIL_DRIVER: "smtp",
  SMTP_HOST: "smtp.example.test",
  SMTP_PORT: "587",
  SMTP_USER: "mailer",
  SMTP_PASSWORD: "test-password",
};

const MESSAGE: TransactionalEmailMessage = {
  attachments: [
    {
      content: new Uint8Array([1, 2, 3]),
      contentType: "application/pdf",
      filename: "signed.pdf",
    },
  ],
  htmlBody: "<p>Signed</p>",
  subject: "Your signed copy",
  template: "completion_notification",
  textBody: "Signed",
  to: "signer@example.test",
};

test("SMTP uses STARTTLS by default on port 587 and supports optional auth", () => {
  assert.deepEqual(readSmtpConfig(SMTP_ENV), {
    config: {
      auth: { pass: "test-password", user: "mailer" },
      host: "smtp.example.test",
      port: 587,
      requireTLS: true,
      secure: false,
    },
    error: null,
  });
});

test("SMTP defaults port 465 to implicit TLS and permits unauthenticated relays", () => {
  assert.deepEqual(
    readSmtpConfig({
      EMAIL_DRIVER: "smtp",
      SMTP_HOST: "mail.example.test",
      SMTP_PORT: "465",
    }),
    {
      config: {
        host: "mail.example.test",
        port: 465,
        requireTLS: false,
        secure: true,
      },
      error: null,
    },
  );
});

test("SMTP hostname resolution requests IPv4 only and keeps the TLS server name", async () => {
  let requestedFamily: number | undefined;

  assert.deepEqual(
    await resolveSmtpHostIpv4(
      "mail.example.test",
      async (hostname, options) => {
        assert.equal(hostname, "mail.example.test");
        requestedFamily = options.family;

        return { address: "192.0.2.25", family: 4 };
      },
    ),
    { host: "192.0.2.25", servername: "mail.example.test" },
  );
  assert.equal(requestedFamily, 4);
  assert.deepEqual(await resolveSmtpHostIpv4("192.0.2.25"), {
    host: "192.0.2.25",
  });
  await assert.rejects(
    resolveSmtpHostIpv4("2001:db8::25"),
    /IPv4-resolvable hostname/,
  );
});

test("SMTP accepts explicit TLS settings and rejects malformed host, port, booleans, and partial auth", () => {
  assert.deepEqual(
    readSmtpConfig({
      EMAIL_DRIVER: "smtp",
      SMTP_HOST: "relay.example.test",
      SMTP_PORT: "2525",
      SMTP_SECURE: "true",
      SMTP_REQUIRE_TLS: "false",
    }),
    {
      config: {
        host: "relay.example.test",
        port: 2525,
        requireTLS: false,
        secure: true,
      },
      error: null,
    },
  );
  assert.match(readSmtpConfig({}).error ?? "", /SMTP_HOST/);
  assert.match(
    readSmtpConfig({ SMTP_HOST: "https://mail.example.test" }).error ?? "",
    /hostname or IP address/,
  );
  assert.match(
    readSmtpConfig({ SMTP_HOST: "2001:db8::25" }).error ?? "",
    /must use IPv4/,
  );
  assert.match(
    readSmtpConfig({ SMTP_HOST: "mail.example.test", SMTP_PORT: "70000" })
      .error ?? "",
    /SMTP_PORT/,
  );
  assert.match(
    readSmtpConfig({ SMTP_HOST: "mail.example.test", SMTP_SECURE: "sometimes" })
      .error ?? "",
    /SMTP_SECURE/,
  );
  assert.match(
    readSmtpConfig({ SMTP_HOST: "mail.example.test", SMTP_USER: "mailer" })
      .error ?? "",
    /both SMTP_USER and SMTP_PASSWORD/,
  );
});

test("the SMTP driver sends message fields and attachments through the injected transport", async () => {
  let sent: Record<string, unknown> | undefined;
  const service = createEmailService({
    env: SMTP_ENV,
    resolveAddresses: async () => ({
      senderAddress: "Acme <sign@acme.example>",
      supportAddress: "help@acme.example",
    }),
    smtpTransport: {
      async sendMail(message: unknown) {
        sent = message as unknown as Record<string, unknown>;

        return {
          accepted: ["signer@example.test"],
          messageId: "smtp-message-1",
          rejected: [],
        };
      },
    } as unknown as SmtpTransport,
  });

  const result = await service.send(MESSAGE);

  assert.deepEqual(result, {
    accepted: ["signer@example.test"],
    messageId: "smtp-message-1",
    rejected: [],
  });
  assert.equal(sent?.from, "Acme <sign@acme.example>");
  assert.equal(sent?.replyTo, "help@acme.example");
  assert.equal(sent?.to, "signer@example.test");
  assert.equal(sent?.subject, "Your signed copy");
  assert.equal(sent?.text, "Signed");
  assert.equal(sent?.html, "<p>Signed</p>");
  assert.deepEqual(sent?.attachments, [
    {
      content: Buffer.from([1, 2, 3]),
      contentType: "application/pdf",
      filename: "signed.pdf",
    },
  ]);
});

test("message reply-to overrides the support address", async () => {
  let sent: Record<string, unknown> | undefined;
  const service = createEmailService({
    env: SMTP_ENV,
    resolveAddresses: async () => ({
      senderAddress: "sign@acme.example",
      supportAddress: "help@acme.example",
    }),
    smtpTransport: {
      async sendMail(message: unknown) {
        sent = message as unknown as Record<string, unknown>;

        return { accepted: ["signer@example.test"], rejected: [] };
      },
    } as unknown as SmtpTransport,
  });

  await service.send({
    ...MESSAGE,
    attachments: undefined,
    replyTo: "owner@acme.example",
  });

  assert.equal(sent?.replyTo, "owner@acme.example");
});

test("SMTP failures and rejected recipients are reported to the caller", async () => {
  const service = createEmailService({
    env: SMTP_ENV,
    resolveAddresses: async () => ({
      senderAddress: "sign@acme.example",
      supportAddress: null,
    }),
    smtpTransport: {
      async sendMail() {
        return { accepted: [], rejected: ["signer@example.test"] };
      },
    } as unknown as SmtpTransport,
  });

  await assert.rejects(
    service.send({ ...MESSAGE, attachments: undefined }),
    /rejected the recipient: signer@example.test/,
  );
});

test("SMTP does not fall back to Resend's shared test sender", async () => {
  let attemptedSend = false;
  const service = createEmailService({
    env: SMTP_ENV,
    resolveAddresses: async () => ({
      senderAddress: "SignuDoc <onboarding@resend.dev>",
      supportAddress: null,
    }),
    smtpTransport: {
      async sendMail() {
        attemptedSend = true;

        return { accepted: ["signer@example.test"], rejected: [] };
      },
    } as unknown as SmtpTransport,
  });

  await assert.rejects(
    service.send({ ...MESSAGE, attachments: undefined }),
    /Set a sender address/,
  );
  assert.equal(attemptedSend, false);
});

test("SMTP batches send each message and preserve result order", async () => {
  const sent: string[] = [];
  const service = createEmailService({
    env: SMTP_ENV,
    resolveAddresses: async () => ({
      senderAddress: "sign@acme.example",
      supportAddress: null,
    }),
    smtpTransport: {
      async sendMail(message: unknown) {
        sent.push(String((message as { to: string }).to));

        return {
          accepted: [String((message as { to: string }).to)],
          messageId: `smtp-${String(sent.length)}`,
          rejected: [],
        };
      },
    } as unknown as SmtpTransport,
  });
  const messages = [
    { ...MESSAGE, attachments: undefined, to: "one@example.test" },
    { ...MESSAGE, attachments: undefined, to: "two@example.test" },
  ];

  const result = await service.sendBatch(messages);

  assert.deepEqual(sent, ["one@example.test", "two@example.test"]);
  assert.deepEqual(
    result.map((delivery) => delivery.messageId),
    ["smtp-1", "smtp-2"],
  );
});

test("EMAIL_DRIVER accepts smtp while leaving Resend as the default", () => {
  assert.equal(resolveEmailDriver({ EMAIL_DRIVER: " SMTP " }), "smtp");
  assert.equal(resolveEmailDriver({}), "resend");
});
