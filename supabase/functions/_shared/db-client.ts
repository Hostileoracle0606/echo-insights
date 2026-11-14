type RpcResult = { data: unknown; error: unknown };

/** The slice of supabase-js the handlers use. */
export interface DbClient {
  auth: {
    getUser(): PromiseLike<{ data: { user: { id: string } | null }; error: unknown }>;
  };
  from(table: string): {
    select(columns: string): {
      eq(column: string, value: string): { single(): PromiseLike<RpcResult> };
    };
  };
  rpc(fn: string, args: Record<string, unknown>): PromiseLike<RpcResult>;
}

/** The chainable query embed-entities runs. */
export interface DbQuery extends PromiseLike<{ data: unknown; error: { code?: string } | null }> {
  select(columns: string): DbQuery;
  eq(column: string, value: string): DbQuery;
  in(column: string, values: string[]): DbQuery;
  delete(): DbQuery;
  single(): DbQuery;
  upsert(rows: unknown[], options?: Record<string, unknown>): DbQuery;
}

export interface TableClient {
  from(table: string): DbQuery;
}
