export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  graphql_public: {
    Tables: {
      [_ in never]: never
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      graphql: {
        Args: {
          extensions?: Json
          operationName?: string
          query?: string
          variables?: Json
        }
        Returns: Json
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
  public: {
    Tables: {
      asked_questions: {
        Row: {
          asked_at: string
          id: string
          notebook_id: string
          question: string
          target_entity_ids: string[]
          user_id: string
        }
        Insert: {
          asked_at?: string
          id?: string
          notebook_id: string
          question: string
          target_entity_ids?: string[]
          user_id: string
        }
        Update: {
          asked_at?: string
          id?: string
          notebook_id?: string
          question?: string
          target_entity_ids?: string[]
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "asked_questions_notebook_id_fkey"
            columns: ["notebook_id"]
            isOneToOne: false
            referencedRelation: "notebooks"
            referencedColumns: ["id"]
          },
        ]
      }
      entities: {
        Row: {
          description: string | null
          first_seen: string
          id: string
          last_seen: string
          mentions: number
          metadata: Json
          name: string
          notebook_id: string
          questions: string[] | null
          type: string
          user_id: string
        }
        Insert: {
          description?: string | null
          first_seen: string
          id: string
          last_seen: string
          mentions?: number
          metadata?: Json
          name: string
          notebook_id: string
          questions?: string[] | null
          type: string
          user_id: string
        }
        Update: {
          description?: string | null
          first_seen?: string
          id?: string
          last_seen?: string
          mentions?: number
          metadata?: Json
          name?: string
          notebook_id?: string
          questions?: string[] | null
          type?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "entities_notebook_id_fkey"
            columns: ["notebook_id"]
            isOneToOne: false
            referencedRelation: "notebooks"
            referencedColumns: ["id"]
          },
        ]
      }
      entity_embeddings: {
        Row: {
          content_hash: string
          embedding: string
          embedding_model: string
          entity_id: string
          notebook_id: string
          updated_at: string
          user_id: string
        }
        Insert: {
          content_hash: string
          embedding: string
          embedding_model: string
          entity_id: string
          notebook_id: string
          updated_at?: string
          user_id: string
        }
        Update: {
          content_hash?: string
          embedding?: string
          embedding_model?: string
          entity_id?: string
          notebook_id?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "entity_embeddings_notebook_id_fkey"
            columns: ["notebook_id"]
            isOneToOne: false
            referencedRelation: "notebooks"
            referencedColumns: ["id"]
          },
        ]
      }
      follow_ups: {
        Row: {
          answered: boolean
          created_at: string
          id: string
          notebook_id: string
          question: string
          reason: string
          target_entity_ids: string[]
          user_id: string
        }
        Insert: {
          answered?: boolean
          created_at?: string
          id?: string
          notebook_id: string
          question: string
          reason?: string
          target_entity_ids?: string[]
          user_id: string
        }
        Update: {
          answered?: boolean
          created_at?: string
          id?: string
          notebook_id?: string
          question?: string
          reason?: string
          target_entity_ids?: string[]
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "follow_ups_notebook_id_fkey"
            columns: ["notebook_id"]
            isOneToOne: false
            referencedRelation: "notebooks"
            referencedColumns: ["id"]
          },
        ]
      }
      journal_entries: {
        Row: {
          created_at: string
          entity_ids: string[]
          id: string
          notebook_id: string
          relation_ids: string[]
          text: string
          user_id: string
        }
        Insert: {
          created_at: string
          entity_ids?: string[]
          id?: string
          notebook_id: string
          relation_ids?: string[]
          text: string
          user_id: string
        }
        Update: {
          created_at?: string
          entity_ids?: string[]
          id?: string
          notebook_id?: string
          relation_ids?: string[]
          text?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "journal_entries_notebook_id_fkey"
            columns: ["notebook_id"]
            isOneToOne: false
            referencedRelation: "notebooks"
            referencedColumns: ["id"]
          },
        ]
      }
      notebook_commit_requests: {
        Row: {
          created_at: string
          notebook_id: string
          request_hash: string
          request_id: string
          result: Json
        }
        Insert: {
          created_at?: string
          notebook_id: string
          request_hash: string
          request_id: string
          result: Json
        }
        Update: {
          created_at?: string
          notebook_id?: string
          request_hash?: string
          request_id?: string
          result?: Json
        }
        Relationships: [
          {
            foreignKeyName: "notebook_commit_requests_notebook_id_fkey"
            columns: ["notebook_id"]
            isOneToOne: false
            referencedRelation: "notebooks"
            referencedColumns: ["id"]
          },
        ]
      }
      notebooks: {
        Row: {
          archived_at: string | null
          conversation_mode: string
          created_at: string
          duration_seconds: number | null
          ended_at: string | null
          entity_count: number
          id: string
          mode_context: Json
          revision: number
          started_at: string
          summary: string | null
          title: string
          title_source: string
          updated_at: string
          user_id: string
        }
        Insert: {
          archived_at?: string | null
          conversation_mode?: string
          created_at?: string
          duration_seconds?: number | null
          ended_at?: string | null
          entity_count?: number
          id?: string
          mode_context?: Json
          revision?: number
          started_at: string
          summary?: string | null
          title: string
          title_source?: string
          updated_at?: string
          user_id: string
        }
        Update: {
          archived_at?: string | null
          conversation_mode?: string
          created_at?: string
          duration_seconds?: number | null
          ended_at?: string | null
          entity_count?: number
          id?: string
          mode_context?: Json
          revision?: number
          started_at?: string
          summary?: string | null
          title?: string
          title_source?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
      profiles: {
        Row: {
          created_at: string
          display_name: string | null
          user_id: string
        }
        Insert: {
          created_at?: string
          display_name?: string | null
          user_id: string
        }
        Update: {
          created_at?: string
          display_name?: string | null
          user_id?: string
        }
        Relationships: []
      }
      relations: {
        Row: {
          created_at: string
          id: string
          label: string
          metadata: Json
          notebook_id: string
          source_id: string
          superseded_at: string | null
          target_id: string
          user_id: string
        }
        Insert: {
          created_at?: string
          id: string
          label: string
          metadata?: Json
          notebook_id: string
          source_id: string
          superseded_at?: string | null
          target_id: string
          user_id: string
        }
        Update: {
          created_at?: string
          id?: string
          label?: string
          metadata?: Json
          notebook_id?: string
          source_id?: string
          superseded_at?: string | null
          target_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "relations_notebook_id_fkey"
            columns: ["notebook_id"]
            isOneToOne: false
            referencedRelation: "notebooks"
            referencedColumns: ["id"]
          },
        ]
      }
      retrieve_rate_limits: {
        Row: {
          count: number
          scope: string
          window_start: string
        }
        Insert: {
          count?: number
          scope: string
          window_start: string
        }
        Update: {
          count?: number
          scope?: string
          window_start?: string
        }
        Relationships: []
      }
    }
    Views: {
      user_entities: {
        Row: {
          description: string | null
          first_seen: string | null
          id: string | null
          last_seen: string | null
          mentions: number | null
          name: string | null
          notebook_count: number | null
          notebook_ids: string[] | null
          type: string | null
          user_id: string | null
        }
        Relationships: []
      }
      user_relations: {
        Row: {
          active: boolean | null
          first_created_at: string | null
          id: string | null
          label: string | null
          notebook_ids: string[] | null
          source_id: string | null
          target_id: string | null
          user_id: string | null
        }
        Relationships: []
      }
    }
    Functions: {
      _commit_answer_follow_up: {
        Args: { p_change: Json; p_notebook_id: string }
        Returns: Json
      }
      _commit_apply_turn: {
        Args: { p_change: Json; p_notebook_id: string; p_uid: string }
        Returns: Json
      }
      _commit_clear_notebook: { Args: { p_notebook_id: string }; Returns: Json }
      bump_retrieve_rate: { Args: { p_notebook_id: string }; Returns: boolean }
      commit_notebook: {
        Args: {
          p_change: Json
          p_expected_revision: number
          p_notebook_id: string
          p_request_id: string
        }
        Returns: Json
      }
      embed_orphan_prune: { Args: never; Returns: undefined }
      embed_reconcile_sweep: { Args: never; Returns: undefined }
      get_entity_mentions: {
        Args: { p_before?: string; p_entity_id: string; p_limit?: number }
        Returns: Json
      }
      get_notebook_snapshot: { Args: { p_notebook_id: string }; Returns: Json }
      get_user_graph: {
        Args: { p_limit?: number; p_types?: string[] }
        Returns: Json
      }
      match_entity_embeddings: {
        Args: {
          p_limit: number
          p_model: string
          p_notebook_id: string
          p_query: string
        }
        Returns: {
          entity_id: string
          score: number
        }[]
      }
      match_user_entity_embeddings: {
        Args: {
          p_limit: number
          p_model: string
          p_query: string
          p_user_id: string
        }
        Returns: {
          entity_id: string
          notebook_id: string
          score: number
        }[]
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  graphql_public: {
    Enums: {},
  },
  public: {
    Enums: {},
  },
} as const

