import { database, ensureSchema, ownerFromRequest, unauthorized } from "../../../../lib/server";

type Mutation = {
  mutationId: string;
  deviceId: string;
  entityKind: string;
  entityId: string;
  hlc: string;
  fields?: Record<string, unknown>;
  deleted?: boolean;
};

export async function POST(request: Request) {
  const ownerId = await ownerFromRequest(request, "write");
  if (!ownerId) return unauthorized();
  const body = await request.json().catch(() => null) as { mutations?: Mutation[] } | null;
  const mutations = body?.mutations;
  if (!Array.isArray(mutations) || mutations.length > 100) {
    return Response.json({ error: "mutations must contain at most 100 items" }, { status: 400 });
  }
  const fieldCount = mutations.reduce((count, mutation) => count + Object.keys(mutation.fields ?? {}).length + (mutation.deleted ? 1 : 0), 0);
  if (fieldCount > 500 || mutations.some(invalidMutation)) {
    return Response.json({ error: "invalid or oversized mutation batch" }, { status: 400 });
  }

  const db = database();
  await ensureSchema(db);
  const statements: D1PreparedStatement[] = [];
  for (const mutation of mutations) {
    statements.push(db.prepare(
      "INSERT OR IGNORE INTO mutations(owner_id, mutation_id, device_id, hlc) VALUES(?, ?, ?, ?)",
    ).bind(ownerId, mutation.mutationId, mutation.deviceId, mutation.hlc));
    const fields = { ...(mutation.fields ?? {}), ...(mutation.deleted ? { _deleted: true } : {}) };
    for (const [field, value] of Object.entries(fields)) {
      statements.push(db.prepare(`
        INSERT INTO entity_fields(owner_id, entity_kind, entity_id, field, value_json, hlc, device_id)
        VALUES(?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(owner_id, entity_kind, entity_id, field) DO UPDATE SET
          value_json=excluded.value_json, hlc=excluded.hlc, device_id=excluded.device_id
        WHERE excluded.hlc > entity_fields.hlc
           OR (excluded.hlc = entity_fields.hlc AND excluded.device_id > entity_fields.device_id)
      `).bind(ownerId, mutation.entityKind, mutation.entityId, field, JSON.stringify(value), mutation.hlc, mutation.deviceId));
    }
    statements.push(db.prepare(
      "INSERT OR IGNORE INTO changes(owner_id, mutation_id, entity_kind, entity_id, hlc) VALUES(?, ?, ?, ?, ?)",
    ).bind(ownerId, mutation.mutationId, mutation.entityKind, mutation.entityId, mutation.hlc));
  }
  // A task mutation expands into many field statements. Keep each D1 batch
  // comfortably below the platform statement limit while preserving the
  // idempotent, per-field conflict rules.
  for (let offset = 0; offset < statements.length; offset += 50) {
    await db.batch(statements.slice(offset, offset + 50));
  }
  const cursor = await db.prepare("SELECT COALESCE(MAX(sequence), 0) AS cursor FROM changes WHERE owner_id = ?")
    .bind(ownerId).first<{ cursor: number }>();
  return Response.json({ accepted: mutations.length, cursor: cursor?.cursor ?? 0 });
}

function invalidMutation(mutation: Mutation) {
  return !mutation || !safe(mutation.mutationId, 120) || !safe(mutation.deviceId, 120)
    || !safe(mutation.entityKind, 40) || !safe(mutation.entityId, 160) || !safe(mutation.hlc, 160)
    || Object.keys(mutation.fields ?? {}).some((field) => !safe(field, 80));
}

function safe(value: unknown, max: number): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= max;
}
