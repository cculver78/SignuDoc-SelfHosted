import { lookup as dnsLookup } from "node:dns/promises";
import { isIP } from "node:net";
import nodemailer from "nodemailer";
import type { Transporter } from "nodemailer";

import {
  extractEmailAddress,
  RESEND_TEST_SENDER_ADDRESS,
} from "./email-addresses.ts";
import type {
  EmailDeliveryResult,
  EmailService,
  TransactionalEmailMessage,
} from "./email.ts";
import type { EmailAddresses } from "./email-addresses.ts";
import { readEnv, type EnvSource } from "../utils/env.ts";

export type SmtpConfig = {
  auth?: { pass: string; user: string };
  host: string;
  port: number;
  requireTLS: boolean;
  secure: boolean;
};

export type SmtpConfigResult =
  { config: SmtpConfig; error: null } | { config: null; error: string };

export type SmtpTransport = Pick<Transporter, "sendMail">;

type Ipv4Lookup = (
  hostname: string,
  options: { family: 4 },
) => Promise<{ address: string; family: number }>;

const lookupIpv4: Ipv4Lookup = (hostname, options) =>
  dnsLookup(hostname, options);

/** Resolves hostnames through A records only; Nodemailer receives an IPv4. */
export async function resolveSmtpHostIpv4(
  host: string,
  lookup: Ipv4Lookup = lookupIpv4,
): Promise<{ host: string; servername?: string }> {
  const family = isIP(host);

  if (family === 4) {
    return { host };
  }

  if (family === 6) {
    throw new Error(
      "SMTP_HOST must be an IPv4 address or an IPv4-resolvable hostname.",
    );
  }

  const resolved = await lookup(host, { family: 4 });

  if (resolved.family !== 4 || isIP(resolved.address) !== 4) {
    throw new Error("SMTP_HOST did not resolve to an IPv4 address.");
  }

  // Preserve TLS certificate validation and SNI for the configured hostname
  // after replacing host with its IPv4 address.
  return { host: resolved.address, servername: host };
}

function readBoolean(
  env: EnvSource,
  name: string,
): { error: string | null; value: boolean | undefined } {
  const value = readEnv(env, name)?.toLowerCase();

  if (value === undefined) {
    return { error: null, value: undefined };
  }

  if (["true", "1", "yes"].includes(value)) {
    return { error: null, value: true };
  }

  if (["false", "0", "no"].includes(value)) {
    return { error: null, value: false };
  }

  return {
    error: `${name} must be true or false.`,
    value: undefined,
  };
}

/** Reads SMTP settings without opening a connection to the mail server. */
export function readSmtpConfig(env: EnvSource): SmtpConfigResult {
  const host = readEnv(env, "SMTP_HOST");

  if (!host) {
    return { config: null, error: "Set SMTP_HOST to your mail server." };
  }

  if (/\s|:\/\//.test(host)) {
    return {
      config: null,
      error:
        "SMTP_HOST must be a hostname or IP address, without a URL scheme.",
    };
  }

  if (isIP(host) === 6) {
    return {
      config: null,
      error: "SMTP_HOST must use IPv4; IPv6 SMTP hosts are not supported.",
    };
  }

  const portValue = readEnv(env, "SMTP_PORT");
  const port = portValue === undefined ? 587 : Number(portValue);

  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    return {
      config: null,
      error: "SMTP_PORT must be a whole number between 1 and 65535.",
    };
  }

  const secureSetting = readBoolean(env, "SMTP_SECURE");

  if (secureSetting.error) {
    return { config: null, error: secureSetting.error };
  }

  const secure = secureSetting.value ?? port === 465;
  const requireTlsSetting = readBoolean(env, "SMTP_REQUIRE_TLS");

  if (requireTlsSetting.error) {
    return { config: null, error: requireTlsSetting.error };
  }

  const user = readEnv(env, "SMTP_USER");
  const pass = readEnv(env, "SMTP_PASSWORD");

  if (Boolean(user) !== Boolean(pass)) {
    return {
      config: null,
      error: "Set both SMTP_USER and SMTP_PASSWORD, or leave both unset.",
    };
  }

  return {
    config: {
      ...(user && pass ? { auth: { pass, user } } : {}),
      host,
      port,
      requireTLS: requireTlsSetting.value ?? !secure,
      secure,
    },
    error: null,
  };
}

type SmtpMessageInfo = {
  accepted?: unknown[];
  messageId?: string;
  rejected?: unknown[];
};

function addressList(values: unknown[] | undefined): string[] {
  return (values ?? []).map((value) => {
    if (typeof value === "string") {
      return value;
    }

    if (typeof value === "object" && value !== null && "address" in value) {
      const address = (value as { address?: unknown }).address;

      if (typeof address === "string") {
        return address;
      }
    }

    return String(value);
  });
}

function buildSmtpPayload(
  message: TransactionalEmailMessage,
  addresses: EmailAddresses,
) {
  return {
    ...(message.attachments?.length
      ? {
          attachments: message.attachments.map((attachment) => ({
            content: Buffer.from(attachment.content),
            contentType: attachment.contentType,
            filename: attachment.filename,
          })),
        }
      : {}),
    from: addresses.senderAddress,
    html: message.htmlBody,
    replyTo: message.replyTo ?? addresses.supportAddress ?? undefined,
    subject: message.subject,
    text: message.textBody,
    to: message.to,
  };
}

export function createSmtpEmailService({
  env,
  resolveAddresses,
  smtpTransport,
}: {
  env: EnvSource;
  resolveAddresses: () => Promise<EmailAddresses>;
  smtpTransport?: SmtpTransport;
}): EmailService {
  const result = readSmtpConfig(env);

  if (result.config === null) {
    throw new Error(result.error);
  }

  const config = result.config;

  let transportPromise: Promise<SmtpTransport> | undefined = smtpTransport
    ? Promise.resolve(smtpTransport)
    : undefined;

  function getTransport(): Promise<SmtpTransport> {
    transportPromise ??= resolveSmtpHostIpv4(config.host).then(
      (resolvedHost) =>
        nodemailer.createTransport({
          ...config,
          ...resolvedHost,
        }) as SmtpTransport,
    );

    return transportPromise;
  }

  async function send(
    message: TransactionalEmailMessage,
  ): Promise<EmailDeliveryResult> {
    const addresses = await resolveAddresses();

    if (
      extractEmailAddress(addresses.senderAddress) ===
      RESEND_TEST_SENDER_ADDRESS
    ) {
      throw new Error(
        "Set a sender address under Settings, Organization or configure SMTP_FROM_EMAIL or EMAIL_FROM_ADDRESS.",
      );
    }

    const transport = await getTransport();
    const info = (await transport.sendMail(
      buildSmtpPayload(message, addresses),
    )) as SmtpMessageInfo;
    const accepted = addressList(info.accepted);
    const rejected = addressList(info.rejected);

    if (accepted.length === 0) {
      throw new Error(
        rejected.length > 0
          ? `SMTP server rejected the recipient: ${rejected.join(", ")}`
          : "SMTP server did not accept any recipients.",
      );
    }

    return {
      accepted,
      ...(info.messageId ? { messageId: info.messageId } : {}),
      rejected,
    };
  }

  return {
    send,
    // SMTP has no provider-side equivalent of Resend's idempotency key.
    async sendBatch(messages) {
      const results: EmailDeliveryResult[] = [];

      for (const message of messages) {
        results.push(await send(message));
      }

      return results;
    },
  };
}
