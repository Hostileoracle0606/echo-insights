export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.5"
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
          id: string
          notebook_id: string
          text: string
          user_id: string
        }
        Insert: {
          created_at: string
          id?: string
          notebook_id: string
          text: string
          user_id: string
        }
        Update: {
          created_at?: string
          id?: string
          notebook_id?: string
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
      notebooks: {
        Row: {
          archived_at: string | null
          created_at: string
          duration_seconds: number | null
          ended_at: string | null
          entity_count: number
          id: string
          started_at: string
          summary: string | null
          title: string
          title_source: string
          updated_at: string
          user_id: string
        }
        Insert: {
          archived_at?: string | null
          created_at?: string
          duration_seconds?: number | null
          ended_at?: string | null
          entity_count?: number
          id?: string
          started_at: string
          summary?: string | null
          title: string
          title_source?: string
          updated_at?: string
          user_id: string
        }
        Update: {
          archived_at?: string | null
          created_at?: string
          duration_seconds?: number | null
          ended_at?: string | null
          entity_count?: number
          id?: string
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
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      [_ in never]: never
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
  public: {
    Enums: {},
  },
} as const
