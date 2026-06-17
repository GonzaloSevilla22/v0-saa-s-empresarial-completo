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
    PostgrestVersion: "14.1"
  }
  community: {
    Tables: {
      copilot_prompts: {
        Row: {
          category: string
          created_at: string | null
          description: string | null
          id: string
          name: string
          prompt_text: string
          status: string | null
          updated_at: string | null
          usage_count: number | null
        }
        Insert: {
          category: string
          created_at?: string | null
          description?: string | null
          id?: string
          name: string
          prompt_text: string
          status?: string | null
          updated_at?: string | null
          usage_count?: number | null
        }
        Update: {
          category?: string
          created_at?: string | null
          description?: string | null
          id?: string
          name?: string
          prompt_text?: string
          status?: string | null
          updated_at?: string | null
          usage_count?: number | null
        }
        Relationships: []
      }
      course_enrollments: {
        Row: {
          course_id: string
          enrolled_at: string
          id: string
          user_id: string
        }
        Insert: {
          course_id: string
          enrolled_at?: string
          id?: string
          user_id: string
        }
        Update: {
          course_id?: string
          enrolled_at?: string
          id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "course_enrollments_course_id_fkey"
            columns: ["course_id"]
            isOneToOne: false
            referencedRelation: "courses"
            referencedColumns: ["id"]
          },
        ]
      }
      course_lessons: {
        Row: {
          content_url: string | null
          created_at: string
          description: string | null
          duration: string | null
          id: string
          module_id: string
          order_index: number
          title: string
        }
        Insert: {
          content_url?: string | null
          created_at?: string
          description?: string | null
          duration?: string | null
          id?: string
          module_id: string
          order_index?: number
          title: string
        }
        Update: {
          content_url?: string | null
          created_at?: string
          description?: string | null
          duration?: string | null
          id?: string
          module_id?: string
          order_index?: number
          title?: string
        }
        Relationships: [
          {
            foreignKeyName: "course_lessons_module_id_fkey"
            columns: ["module_id"]
            isOneToOne: false
            referencedRelation: "course_modules"
            referencedColumns: ["id"]
          },
        ]
      }
      course_modules: {
        Row: {
          course_id: string
          created_at: string
          id: string
          order_index: number
          title: string
        }
        Insert: {
          course_id: string
          created_at?: string
          id?: string
          order_index?: number
          title: string
        }
        Update: {
          course_id?: string
          created_at?: string
          id?: string
          order_index?: number
          title?: string
        }
        Relationships: [
          {
            foreignKeyName: "course_modules_course_id_fkey"
            columns: ["course_id"]
            isOneToOne: false
            referencedRelation: "courses"
            referencedColumns: ["id"]
          },
        ]
      }
      course_progress: {
        Row: {
          account_id: string | null
          completed: boolean
          course_id: string
          created_at: string
          id: string
          user_id: string
        }
        Insert: {
          account_id?: string | null
          completed?: boolean
          course_id: string
          created_at?: string
          id?: string
          user_id: string
        }
        Update: {
          account_id?: string | null
          completed?: boolean
          course_id?: string
          created_at?: string
          id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "course_progress_course_id_fkey"
            columns: ["course_id"]
            isOneToOne: false
            referencedRelation: "courses"
            referencedColumns: ["id"]
          },
        ]
      }
      courses: {
        Row: {
          category: string
          content: string
          created_at: string
          description: string
          id: string
          is_pro: boolean
          level: string
          rating: number
          students: number
          title: string
        }
        Insert: {
          category?: string
          content: string
          created_at?: string
          description: string
          id?: string
          is_pro?: boolean
          level?: string
          rating?: number
          students?: number
          title: string
        }
        Update: {
          category?: string
          content?: string
          created_at?: string
          description?: string
          id?: string
          is_pro?: boolean
          level?: string
          rating?: number
          students?: number
          title?: string
        }
        Relationships: []
      }
      fair_ai_tools: {
        Row: {
          category: string
          clicks_count: number | null
          created_at: string | null
          description: string | null
          id: string
          link: string | null
          name: string
          status: string | null
          updated_at: string | null
        }
        Insert: {
          category: string
          clicks_count?: number | null
          created_at?: string | null
          description?: string | null
          id?: string
          link?: string | null
          name: string
          status?: string | null
          updated_at?: string | null
        }
        Update: {
          category?: string
          clicks_count?: number | null
          created_at?: string | null
          description?: string | null
          id?: string
          link?: string | null
          name?: string
          status?: string | null
          updated_at?: string | null
        }
        Relationships: []
      }
      fair_recommendations: {
        Row: {
          account_id: string | null
          created_at: string
          id: string
          recommendation: Json
          user_id: string
        }
        Insert: {
          account_id?: string | null
          created_at?: string
          id?: string
          recommendation: Json
          user_id?: string
        }
        Update: {
          account_id?: string | null
          created_at?: string
          id?: string
          recommendation?: Json
          user_id?: string
        }
        Relationships: []
      }
      landing_sections: {
        Row: {
          active: boolean | null
          button_link: string | null
          button_text: string | null
          content: string | null
          created_at: string
          id: string
          image_url: string | null
          position: number | null
          slug: string
          subtitle: string | null
          title: string | null
          type: string
          updated_at: string
        }
        Insert: {
          active?: boolean | null
          button_link?: string | null
          button_text?: string | null
          content?: string | null
          created_at?: string
          id?: string
          image_url?: string | null
          position?: number | null
          slug: string
          subtitle?: string | null
          title?: string | null
          type: string
          updated_at?: string
        }
        Update: {
          active?: boolean | null
          button_link?: string | null
          button_text?: string | null
          content?: string | null
          created_at?: string
          id?: string
          image_url?: string | null
          position?: number | null
          slug?: string
          subtitle?: string | null
          title?: string | null
          type?: string
          updated_at?: string
        }
        Relationships: []
      }
      lesson_progress: {
        Row: {
          completed: boolean
          id: string
          lesson_id: string
          updated_at: string
          user_id: string
        }
        Insert: {
          completed?: boolean
          id?: string
          lesson_id: string
          updated_at?: string
          user_id: string
        }
        Update: {
          completed?: boolean
          id?: string
          lesson_id?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "lesson_progress_lesson_id_fkey"
            columns: ["lesson_id"]
            isOneToOne: false
            referencedRelation: "course_lessons"
            referencedColumns: ["id"]
          },
        ]
      }
      meetings: {
        Row: {
          created_at: string | null
          description: string | null
          id: string
          meeting_url: string
          start_time: string
          title: string
        }
        Insert: {
          created_at?: string | null
          description?: string | null
          id?: string
          meeting_url: string
          start_time: string
          title: string
        }
        Update: {
          created_at?: string | null
          description?: string | null
          id?: string
          meeting_url?: string
          start_time?: string
          title?: string
        }
        Relationships: []
      }
      post_likes: {
        Row: {
          created_at: string
          id: string
          post_id: string
          user_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          post_id: string
          user_id: string
        }
        Update: {
          created_at?: string
          id?: string
          post_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "post_likes_post_id_fkey"
            columns: ["post_id"]
            isOneToOne: false
            referencedRelation: "posts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "post_likes_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      posts: {
        Row: {
          category: string | null
          content: string
          created_at: string
          id: string
          likes_count: number
          replies_count: number
          title: string
          user_id: string
        }
        Insert: {
          category?: string | null
          content: string
          created_at?: string
          id?: string
          likes_count?: number
          replies_count?: number
          title: string
          user_id: string
        }
        Update: {
          category?: string | null
          content?: string
          created_at?: string
          id?: string
          likes_count?: number
          replies_count?: number
          title?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "posts_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      purchase_pools: {
        Row: {
          closes_at: string
          created_at: string | null
          current_amount: number | null
          description: string | null
          id: string
          status: string | null
          target_amount: number
          title: string
        }
        Insert: {
          closes_at: string
          created_at?: string | null
          current_amount?: number | null
          description?: string | null
          id?: string
          status?: string | null
          target_amount: number
          title: string
        }
        Update: {
          closes_at?: string
          created_at?: string | null
          current_amount?: number | null
          description?: string | null
          id?: string
          status?: string | null
          target_amount?: number
          title?: string
        }
        Relationships: []
      }
      replies: {
        Row: {
          content: string
          created_at: string
          id: string
          post_id: string
          user_id: string
        }
        Insert: {
          content: string
          created_at?: string
          id?: string
          post_id: string
          user_id: string
        }
        Update: {
          content?: string
          created_at?: string
          id?: string
          post_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "replies_post_id_fkey"
            columns: ["post_id"]
            isOneToOne: false
            referencedRelation: "posts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "replies_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      seguros: {
        Row: {
          clicks_count: number | null
          contact_url: string | null
          coverage: string | null
          created_at: string | null
          description: string | null
          id: string
          is_visible: boolean | null
          price: string | null
          title: string
          updated_at: string | null
        }
        Insert: {
          clicks_count?: number | null
          contact_url?: string | null
          coverage?: string | null
          created_at?: string | null
          description?: string | null
          id?: string
          is_visible?: boolean | null
          price?: string | null
          title: string
          updated_at?: string | null
        }
        Update: {
          clicks_count?: number | null
          contact_url?: string | null
          coverage?: string | null
          created_at?: string | null
          description?: string | null
          id?: string
          is_visible?: boolean | null
          price?: string | null
          title?: string
          updated_at?: string | null
        }
        Relationships: []
      }
    }
    Views: {
      profiles: {
        Row: {
          avatar_url: string | null
          id: string | null
          name: string | null
        }
        Insert: {
          avatar_url?: string | null
          id?: string | null
          name?: string | null
        }
        Update: {
          avatar_url?: string | null
          id?: string | null
          name?: string | null
        }
        Relationships: []
      }
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
  public: {
    Tables: {
      account_feature_flags: {
        Row: {
          account_id: string
          created_at: string | null
          enabled: boolean
          flag_key: string
          updated_at: string | null
        }
        Insert: {
          account_id: string
          created_at?: string | null
          enabled?: boolean
          flag_key: string
          updated_at?: string | null
        }
        Update: {
          account_id?: string
          created_at?: string | null
          enabled?: boolean
          flag_key?: string
          updated_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "account_feature_flags_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
        ]
      }
      account_invitations: {
        Row: {
          account_id: string
          created_at: string
          email: string
          expires_at: string
          id: string
          invited_by: string
          role: string
          status: string
          token: string
        }
        Insert: {
          account_id: string
          created_at?: string
          email: string
          expires_at?: string
          id?: string
          invited_by: string
          role?: string
          status?: string
          token: string
        }
        Update: {
          account_id?: string
          created_at?: string
          email?: string
          expires_at?: string
          id?: string
          invited_by?: string
          role?: string
          status?: string
          token?: string
        }
        Relationships: [
          {
            foreignKeyName: "account_invitations_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
        ]
      }
      account_members: {
        Row: {
          account_id: string
          created_at: string
          id: string
          role: string
          user_id: string
        }
        Insert: {
          account_id: string
          created_at?: string
          id?: string
          role?: string
          user_id: string
        }
        Update: {
          account_id?: string
          created_at?: string
          id?: string
          role?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "account_members_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
        ]
      }
      accounts: {
        Row: {
          billing_plan: string
          billing_status: string
          created_at: string
          id: string
          owner_user_id: string
          plan_expires_at: string | null
          trial_expires_at: string | null
          trial_plan: string | null
          trial_started_at: string | null
        }
        Insert: {
          billing_plan?: string
          billing_status?: string
          created_at?: string
          id?: string
          owner_user_id: string
          plan_expires_at?: string | null
          trial_expires_at?: string | null
          trial_plan?: string | null
          trial_started_at?: string | null
        }
        Update: {
          billing_plan?: string
          billing_status?: string
          created_at?: string
          id?: string
          owner_user_id?: string
          plan_expires_at?: string | null
          trial_expires_at?: string | null
          trial_plan?: string | null
          trial_started_at?: string | null
        }
        Relationships: []
      }
      ai_conversations: {
        Row: {
          account_id: string | null
          answer: string
          created_at: string
          id: string
          question: string
          user_id: string
        }
        Insert: {
          account_id?: string | null
          answer: string
          created_at?: string
          id?: string
          question: string
          user_id?: string
        }
        Update: {
          account_id?: string | null
          answer?: string
          created_at?: string
          id?: string
          question?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "ai_conversations_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
        ]
      }
      ai_insights: {
        Row: {
          account_id: string | null
          created_at: string
          id: string
          message: string
          priority: string
          type: string
          user_id: string
        }
        Insert: {
          account_id?: string | null
          created_at?: string
          id?: string
          message: string
          priority: string
          type: string
          user_id?: string
        }
        Update: {
          account_id?: string | null
          created_at?: string
          id?: string
          message?: string
          priority?: string
          type?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "ai_insights_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
        ]
      }
      analytics_events: {
        Row: {
          created_at: string
          event_data: Json | null
          event_name: string
          id: string
          user_id: string | null
        }
        Insert: {
          created_at?: string
          event_data?: Json | null
          event_name: string
          id?: string
          user_id?: string | null
        }
        Update: {
          created_at?: string
          event_data?: Json | null
          event_name?: string
          id?: string
          user_id?: string | null
        }
        Relationships: []
      }
      audit_logs: {
        Row: {
          action: string
          company_id: string
          created_at: string
          entity_id: string | null
          entity_type: string
          id: string
          metadata: Json | null
          user_id: string | null
        }
        Insert: {
          action: string
          company_id: string
          created_at?: string
          entity_id?: string | null
          entity_type: string
          id?: string
          metadata?: Json | null
          user_id?: string | null
        }
        Update: {
          action?: string
          company_id?: string
          created_at?: string
          entity_id?: string | null
          entity_type?: string
          id?: string
          metadata?: Json | null
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "audit_logs_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
        ]
      }
      billing_events: {
        Row: {
          amount: number | null
          created_at: string
          event_type: string
          from_plan: string | null
          id: string
          mercadopago_payment_id: string | null
          mercadopago_preference_id: string | null
          metadata: Json | null
          reason: string | null
          to_plan: string | null
          user_id: string
        }
        Insert: {
          amount?: number | null
          created_at?: string
          event_type: string
          from_plan?: string | null
          id?: string
          mercadopago_payment_id?: string | null
          mercadopago_preference_id?: string | null
          metadata?: Json | null
          reason?: string | null
          to_plan?: string | null
          user_id: string
        }
        Update: {
          amount?: number | null
          created_at?: string
          event_type?: string
          from_plan?: string | null
          id?: string
          mercadopago_payment_id?: string | null
          mercadopago_preference_id?: string | null
          metadata?: Json | null
          reason?: string | null
          to_plan?: string | null
          user_id?: string
        }
        Relationships: []
      }
      branch_stock: {
        Row: {
          account_id: string
          branch_id: string
          id: string
          min_stock: number
          product_id: string
          quantity: number
        }
        Insert: {
          account_id: string
          branch_id: string
          id?: string
          min_stock?: number
          product_id: string
          quantity?: number
        }
        Update: {
          account_id?: string
          branch_id?: string
          id?: string
          min_stock?: number
          product_id?: string
          quantity?: number
        }
        Relationships: [
          {
            foreignKeyName: "branch_stock_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "branch_stock_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "branch_stock_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "branch_stock_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "v_products_with_stock"
            referencedColumns: ["id"]
          },
        ]
      }
      // ── C-28: cashboxes / cash_sessions / cash_movements ───────────────────
      cashboxes: {
        Row: {
          created_at: string
          currency: string
          id: string
          branch_id: string
          name: string
        }
        Insert: {
          created_at?: string
          currency?: string
          id?: string
          branch_id: string
          name: string
        }
        Update: {
          created_at?: string
          currency?: string
          id?: string
          branch_id?: string
          name?: string
        }
        Relationships: [
          {
            foreignKeyName: "cashboxes_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
        ]
      }
      cash_sessions: {
        Row: {
          cashbox_id: string
          closed_at: string | null
          closed_by: string | null
          closing_balance: number | null
          counted_balance: number | null
          difference: number | null
          expected_balance: number | null
          id: string
          opened_at: string
          opened_by: string
          opening_balance: number
          status: string
        }
        Insert: {
          cashbox_id: string
          closed_at?: string | null
          closed_by?: string | null
          closing_balance?: number | null
          counted_balance?: number | null
          difference?: number | null
          expected_balance?: number | null
          id?: string
          opened_at?: string
          opened_by: string
          opening_balance: number
          status?: string
        }
        Update: {
          cashbox_id?: string
          closed_at?: string | null
          closed_by?: string | null
          closing_balance?: number | null
          counted_balance?: number | null
          difference?: number | null
          expected_balance?: number | null
          id?: string
          opened_at?: string
          opened_by?: string
          opening_balance?: number
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "cash_sessions_cashbox_id_fkey"
            columns: ["cashbox_id"]
            isOneToOne: false
            referencedRelation: "cashboxes"
            referencedColumns: ["id"]
          },
        ]
      }
      cash_movements: {
        Row: {
          amount: number
          balance_after: number
          created_at: string
          created_by: string
          id: string
          movement_type: string
          reference_id: string | null
          session_id: string
        }
        Insert: {
          amount: number
          balance_after: number
          created_at?: string
          created_by: string
          id?: string
          movement_type: string
          reference_id?: string | null
          session_id: string
        }
        Update: {
          amount?: number
          balance_after?: number
          created_at?: string
          created_by?: string
          id?: string
          movement_type?: string
          reference_id?: string | null
          session_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "cash_movements_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "cash_sessions"
            referencedColumns: ["id"]
          },
        ]
      }
      branches: {
        Row: {
          account_id: string
          address: string | null
          closed_at: string | null
          created_at: string
          id: string
          is_active: boolean
          name: string
          opened_at: string | null
          status: string
        }
        Insert: {
          account_id: string
          address?: string | null
          closed_at?: string | null
          created_at?: string
          id?: string
          is_active?: boolean
          name: string
          opened_at?: string | null
          status?: string
        }
        Update: {
          account_id?: string
          address?: string | null
          closed_at?: string | null
          created_at?: string
          id?: string
          is_active?: boolean
          name?: string
          opened_at?: string | null
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "branches_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
        ]
      }
      clients: {
        Row: {
          account_id: string | null
          category: string | null
          company_id: string | null
          created_at: string
          deleted_at: string | null
          email: string | null
          id: string
          iva_condition: string | null
          legal_name: string | null
          name: string
          phone: string | null
          status: string
          tax_id: string | null
          user_id: string
        }
        Insert: {
          account_id?: string | null
          category?: string | null
          company_id?: string | null
          created_at?: string
          deleted_at?: string | null
          email?: string | null
          id?: string
          iva_condition?: string | null
          legal_name?: string | null
          name: string
          phone?: string | null
          status?: string
          tax_id?: string | null
          user_id?: string
        }
        Update: {
          account_id?: string | null
          category?: string | null
          company_id?: string | null
          created_at?: string
          deleted_at?: string | null
          email?: string | null
          id?: string
          iva_condition?: string | null
          legal_name?: string | null
          name?: string
          phone?: string | null
          status?: string
          tax_id?: string | null
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "clients_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "clients_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
        ]
      }
      companies: {
        Row: {
          created_at: string
          id: string
          name: string
        }
        Insert: {
          created_at?: string
          id?: string
          name: string
        }
        Update: {
          created_at?: string
          id?: string
          name?: string
        }
        Relationships: []
      }
      company_users: {
        Row: {
          company_id: string
          created_at: string
          id: string
          role: string
          user_id: string
        }
        Insert: {
          company_id: string
          created_at?: string
          id?: string
          role: string
          user_id: string
        }
        Update: {
          company_id?: string
          created_at?: string
          id?: string
          role?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "company_users_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
        ]
      }
      document_sequences: {
        Row: {
          comprobante_type: string
          created_at: string
          id: string
          last_number: number
          point_of_sale_id: string
        }
        Insert: {
          comprobante_type: string
          created_at?: string
          id?: string
          last_number?: number
          point_of_sale_id: string
        }
        Update: {
          comprobante_type?: string
          created_at?: string
          id?: string
          last_number?: number
          point_of_sale_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "document_sequences_point_of_sale_id_fkey"
            columns: ["point_of_sale_id"]
            isOneToOne: false
            referencedRelation: "points_of_sale"
            referencedColumns: ["id"]
          },
        ]
      }
      email_logs: {
        Row: {
          created_at: string
          error_details: string | null
          event_type: string
          id: string
          metadata: Json | null
          provider_id: string | null
          recipient: string
          sent_at: string | null
          status: string
          subject: string
          user_id: string | null
        }
        Insert: {
          created_at?: string
          error_details?: string | null
          event_type: string
          id?: string
          metadata?: Json | null
          provider_id?: string | null
          recipient: string
          sent_at?: string | null
          status?: string
          subject: string
          user_id?: string | null
        }
        Update: {
          created_at?: string
          error_details?: string | null
          event_type?: string
          id?: string
          metadata?: Json | null
          provider_id?: string | null
          recipient?: string
          sent_at?: string | null
          status?: string
          subject?: string
          user_id?: string | null
        }
        Relationships: []
      }
      events: {
        Row: {
          company_id: string
          created_at: string
          entity_id: string | null
          entity_type: string
          event_type: string
          id: string
          payload: Json | null
        }
        Insert: {
          company_id: string
          created_at?: string
          entity_id?: string | null
          entity_type: string
          event_type: string
          id?: string
          payload?: Json | null
        }
        Update: {
          company_id?: string
          created_at?: string
          entity_id?: string | null
          entity_type?: string
          event_type?: string
          id?: string
          payload?: Json | null
        }
        Relationships: [
          {
            foreignKeyName: "events_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
        ]
      }
      expenses: {
        Row: {
          account_id: string | null
          amount: number
          branch_id: string | null
          category: string
          company_id: string | null
          created_at: string
          date: string
          description: string | null
          id: string
          user_id: string
        }
        Insert: {
          account_id?: string | null
          amount: number
          branch_id?: string | null
          category: string
          company_id?: string | null
          created_at?: string
          date?: string
          description?: string | null
          id?: string
          user_id?: string
        }
        Update: {
          account_id?: string | null
          amount?: number
          branch_id?: string | null
          category?: string
          company_id?: string | null
          created_at?: string
          date?: string
          description?: string | null
          id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "expenses_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expenses_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expenses_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
        ]
      }
      export_logs: {
        Row: {
          created_at: string
          export_type: string
          file_path: string
          id: string
          org_id: string | null
          signed_url: string | null
          signed_url_expires_at: string | null
          status: string
          user_id: string
        }
        Insert: {
          created_at?: string
          export_type: string
          file_path: string
          id?: string
          org_id?: string | null
          signed_url?: string | null
          signed_url_expires_at?: string | null
          status?: string
          user_id: string
        }
        Update: {
          created_at?: string
          export_type?: string
          file_path?: string
          id?: string
          org_id?: string | null
          signed_url?: string | null
          signed_url_expires_at?: string | null
          status?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "export_logs_org_id_fkey"
            columns: ["org_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
        ]
      }
      fiscal_documents: {
        Row: {
          account_id: string
          attempts: number
          cae: string | null
          cae_due_date: string | null
          client_id: string | null
          comprobante_type: string
          created_at: string
          fiscal_profile_id: string
          id: string
          last_error: string | null
          next_attempt_at: string | null
          number: number
          point_of_sale_id: string
          punto_de_venta: number
          status: string
          total: number
        }
        Insert: {
          account_id: string
          attempts?: number
          cae?: string | null
          cae_due_date?: string | null
          client_id?: string | null
          comprobante_type: string
          created_at?: string
          fiscal_profile_id: string
          id?: string
          last_error?: string | null
          next_attempt_at?: string | null
          number: number
          point_of_sale_id: string
          punto_de_venta: number
          status?: string
          total?: number
        }
        Update: {
          account_id?: string
          attempts?: number
          cae?: string | null
          cae_due_date?: string | null
          client_id?: string | null
          comprobante_type?: string
          created_at?: string
          fiscal_profile_id?: string
          id?: string
          last_error?: string | null
          next_attempt_at?: string | null
          number?: number
          point_of_sale_id?: string
          punto_de_venta?: number
          status?: string
          total?: number
        }
        Relationships: [
          {
            foreignKeyName: "fiscal_documents_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fiscal_documents_client_id_fkey"
            columns: ["client_id"]
            isOneToOne: false
            referencedRelation: "clients"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fiscal_documents_fiscal_profile_id_fkey"
            columns: ["fiscal_profile_id"]
            isOneToOne: false
            referencedRelation: "fiscal_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fiscal_documents_point_of_sale_id_fkey"
            columns: ["point_of_sale_id"]
            isOneToOne: false
            referencedRelation: "points_of_sale"
            referencedColumns: ["id"]
          },
        ]
      }
      fiscal_profiles: {
        Row: {
          account_id: string
          ambiente: string
          certificado_afip_path: string | null
          created_at: string
          cuit: string
          id: string
          iibb_condition: string | null
          iva_condition: string
        }
        Insert: {
          account_id: string
          ambiente?: string
          certificado_afip_path?: string | null
          created_at?: string
          cuit: string
          id?: string
          iibb_condition?: string | null
          iva_condition: string
        }
        Update: {
          account_id?: string
          ambiente?: string
          certificado_afip_path?: string | null
          created_at?: string
          cuit?: string
          id?: string
          iibb_condition?: string | null
          iva_condition?: string
        }
        Relationships: [
          {
            foreignKeyName: "fiscal_profiles_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: true
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
        ]
      }
      insights: {
        Row: {
          account_id: string | null
          created_at: string
          id: string
          message: string
          priority: string
          type: string
          user_id: string
        }
        Insert: {
          account_id?: string | null
          created_at?: string
          id?: string
          message: string
          priority: string
          type: string
          user_id?: string
        }
        Update: {
          account_id?: string | null
          created_at?: string
          id?: string
          message?: string
          priority?: string
          type?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "insights_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
        ]
      }
      invoice_documents: {
        Row: {
          account_id: string | null
          ai_confidence: number | null
          ai_model: string | null
          ai_raw_response: Json | null
          ai_warnings: string[] | null
          created_at: string | null
          error_message: string | null
          file_size_bytes: number | null
          id: string
          invoice_currency: string | null
          invoice_date: string | null
          invoice_number: string | null
          invoice_total: number | null
          invoice_type: string | null
          mime_type: string | null
          original_name: string | null
          parsed_items: Json | null
          processing_ms: number | null
          purchase_operation_id: string | null
          status: string
          storage_path: string
          supplier_cuit: string | null
          supplier_name: string | null
          updated_at: string | null
          user_id: string
        }
        Insert: {
          account_id?: string | null
          ai_confidence?: number | null
          ai_model?: string | null
          ai_raw_response?: Json | null
          ai_warnings?: string[] | null
          created_at?: string | null
          error_message?: string | null
          file_size_bytes?: number | null
          id?: string
          invoice_currency?: string | null
          invoice_date?: string | null
          invoice_number?: string | null
          invoice_total?: number | null
          invoice_type?: string | null
          mime_type?: string | null
          original_name?: string | null
          parsed_items?: Json | null
          processing_ms?: number | null
          purchase_operation_id?: string | null
          status?: string
          storage_path: string
          supplier_cuit?: string | null
          supplier_name?: string | null
          updated_at?: string | null
          user_id: string
        }
        Update: {
          account_id?: string | null
          ai_confidence?: number | null
          ai_model?: string | null
          ai_raw_response?: Json | null
          ai_warnings?: string[] | null
          created_at?: string | null
          error_message?: string | null
          file_size_bytes?: number | null
          id?: string
          invoice_currency?: string | null
          invoice_date?: string | null
          invoice_number?: string | null
          invoice_total?: number | null
          invoice_type?: string | null
          mime_type?: string | null
          original_name?: string | null
          parsed_items?: Json | null
          processing_ms?: number | null
          purchase_operation_id?: string | null
          status?: string
          storage_path?: string
          supplier_cuit?: string | null
          supplier_name?: string | null
          updated_at?: string | null
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "invoice_documents_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
        ]
      }
      invoice_suppliers: {
        Row: {
          account_id: string | null
          address: string | null
          created_at: string | null
          cuit: string | null
          email: string | null
          id: string
          name: string
          notes: string | null
          phone: string | null
          updated_at: string | null
          user_id: string
        }
        Insert: {
          account_id?: string | null
          address?: string | null
          created_at?: string | null
          cuit?: string | null
          email?: string | null
          id?: string
          name: string
          notes?: string | null
          phone?: string | null
          updated_at?: string | null
          user_id: string
        }
        Update: {
          account_id?: string | null
          address?: string | null
          created_at?: string | null
          cuit?: string | null
          email?: string | null
          id?: string
          name?: string
          notes?: string | null
          phone?: string | null
          updated_at?: string | null
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "invoice_suppliers_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
        ]
      }
      operation_idempotency: {
        Row: {
          account_id: string | null
          created_at: string
          id: string
          idempotency_key: string
          operation_id: string
          operation_kind: string
          user_id: string
        }
        Insert: {
          account_id?: string | null
          created_at?: string
          id?: string
          idempotency_key: string
          operation_id: string
          operation_kind: string
          user_id: string
        }
        Update: {
          account_id?: string | null
          created_at?: string
          id?: string
          idempotency_key?: string
          operation_id?: string
          operation_kind?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "operation_idempotency_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
        ]
      }
      plan_limits: {
        Row: {
          created_at: string
          has_branches_module: boolean
          has_comparative_reports: boolean
          has_monthly_analysis: boolean
          has_price_suggestion: boolean
          has_product_profitability: boolean
          history_days: number
          internal_roles: string
          max_ai_advice_per_month: number
          max_ai_queries_per_month: number
          max_branches: number
          max_clients: number
          max_exports_per_month: number
          max_operations_per_month: number
          max_products: number
          max_suppliers: number
          max_users: number
          plan: string
          price_ars_annual: number
          price_monthly: number
        }
        Insert: {
          created_at?: string
          has_branches_module?: boolean
          has_comparative_reports?: boolean
          has_monthly_analysis?: boolean
          has_price_suggestion?: boolean
          has_product_profitability?: boolean
          history_days?: number
          internal_roles?: string
          max_ai_advice_per_month?: number
          max_ai_queries_per_month?: number
          max_branches?: number
          max_clients?: number
          max_exports_per_month?: number
          max_operations_per_month?: number
          max_products?: number
          max_suppliers?: number
          max_users?: number
          plan: string
          price_ars_annual?: number
          price_monthly?: number
        }
        Update: {
          created_at?: string
          has_branches_module?: boolean
          has_comparative_reports?: boolean
          has_monthly_analysis?: boolean
          has_price_suggestion?: boolean
          has_product_profitability?: boolean
          history_days?: number
          internal_roles?: string
          max_ai_advice_per_month?: number
          max_ai_queries_per_month?: number
          max_branches?: number
          max_clients?: number
          max_exports_per_month?: number
          max_operations_per_month?: number
          max_products?: number
          max_suppliers?: number
          max_users?: number
          plan?: string
          price_ars_annual?: number
          price_monthly?: number
        }
        Relationships: []
      }
      points_of_sale: {
        Row: {
          account_id: string
          branch_id: string | null
          created_at: string
          fiscal_profile_id: string
          id: string
          is_active: boolean
          numero: number
        }
        Insert: {
          account_id: string
          branch_id?: string | null
          created_at?: string
          fiscal_profile_id: string
          id?: string
          is_active?: boolean
          numero: number
        }
        Update: {
          account_id?: string
          branch_id?: string | null
          created_at?: string
          fiscal_profile_id?: string
          id?: string
          is_active?: boolean
          numero?: number
        }
        Relationships: [
          {
            foreignKeyName: "points_of_sale_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "points_of_sale_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "points_of_sale_fiscal_profile_id_fkey"
            columns: ["fiscal_profile_id"]
            isOneToOne: false
            referencedRelation: "fiscal_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      product_aliases: {
        Row: {
          account_id: string | null
          alias: string
          created_at: string | null
          id: string
          product_id: string
          source: string | null
          user_id: string
        }
        Insert: {
          account_id?: string | null
          alias: string
          created_at?: string | null
          id?: string
          product_id: string
          source?: string | null
          user_id: string
        }
        Update: {
          account_id?: string | null
          alias?: string
          created_at?: string | null
          id?: string
          product_id?: string
          source?: string | null
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "product_aliases_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "product_aliases_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "product_aliases_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "v_products_with_stock"
            referencedColumns: ["id"]
          },
        ]
      }
      product_attributes: {
        Row: {
          created_at: string
          id: string
          key: string
          product_id: string
          sort_order: number
          user_id: string
          value: string
        }
        Insert: {
          created_at?: string
          id?: string
          key: string
          product_id: string
          sort_order?: number
          user_id: string
          value: string
        }
        Update: {
          created_at?: string
          id?: string
          key?: string
          product_id?: string
          sort_order?: number
          user_id?: string
          value?: string
        }
        Relationships: [
          {
            foreignKeyName: "product_attributes_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "product_attributes_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "v_products_with_stock"
            referencedColumns: ["id"]
          },
        ]
      }
      product_variants: {
        Row: {
          attributes: Json | null
          barcode: string | null
          cost: number
          created_at: string
          id: string
          price: number
          product_id: string
          sku: string | null
        }
        Insert: {
          attributes?: Json | null
          barcode?: string | null
          cost?: number
          created_at?: string
          id?: string
          price?: number
          product_id: string
          sku?: string | null
        }
        Update: {
          attributes?: Json | null
          barcode?: string | null
          cost?: number
          created_at?: string
          id?: string
          price?: number
          product_id?: string
          sku?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "product_variants_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "product_variants_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "v_products_with_stock"
            referencedColumns: ["id"]
          },
        ]
      }
      products: {
        Row: {
          account_id: string | null
          barcode: string | null
          base_unit_id: string | null
          category: string | null
          company_id: string | null
          cost: number
          created_at: string
          deleted_at: string | null
          id: string
          is_variant: boolean
          min_stock: number
          name: string
          parent_id: string | null
          price: number
          sku: string | null
          stock_control_type: string
          user_id: string
        }
        Insert: {
          account_id?: string | null
          barcode?: string | null
          base_unit_id?: string | null
          category?: string | null
          company_id?: string | null
          cost?: number
          created_at?: string
          deleted_at?: string | null
          id?: string
          is_variant?: boolean
          min_stock?: number
          name: string
          parent_id?: string | null
          price?: number
          sku?: string | null
          stock_control_type?: string
          user_id?: string
        }
        Update: {
          account_id?: string | null
          barcode?: string | null
          base_unit_id?: string | null
          category?: string | null
          company_id?: string | null
          cost?: number
          created_at?: string
          deleted_at?: string | null
          id?: string
          is_variant?: boolean
          min_stock?: number
          name?: string
          parent_id?: string | null
          price?: number
          sku?: string | null
          stock_control_type?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "products_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "products_base_unit_id_fkey"
            columns: ["base_unit_id"]
            isOneToOne: false
            referencedRelation: "units_of_measure"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "products_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "products_parent_id_fkey"
            columns: ["parent_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "products_parent_id_fkey"
            columns: ["parent_id"]
            isOneToOne: false
            referencedRelation: "v_products_with_stock"
            referencedColumns: ["id"]
          },
        ]
      }
      profiles: {
        Row: {
          ai_advice_used: number
          ai_queries_used: number
          avatar_url: string | null
          billing_plan: string
          billing_provider_customer_id: string | null
          billing_status: string
          bio: string | null
          business_name: string | null
          created_at: string
          currency: string
          date_format: string
          exports_used: number
          id: string
          insights_reset_at: string
          insights_used: number
          language: string
          last_name: string | null
          locality: string | null
          name: string | null
          overstock_threshold: number | null
          phone: string | null
          plan: Database["public"]["Enums"]["user_plan"]
          role: Database["public"]["Enums"]["user_role"]
          timezone: string
          trial_expires_at: string | null
          trial_plan: string | null
          trial_started_at: string | null
          updated_at: string
          usage_reset_at: string
        }
        Insert: {
          ai_advice_used?: number
          ai_queries_used?: number
          avatar_url?: string | null
          billing_plan?: string
          billing_provider_customer_id?: string | null
          billing_status?: string
          bio?: string | null
          business_name?: string | null
          created_at?: string
          currency?: string
          date_format?: string
          exports_used?: number
          id: string
          insights_reset_at?: string
          insights_used?: number
          language?: string
          last_name?: string | null
          locality?: string | null
          name?: string | null
          overstock_threshold?: number | null
          phone?: string | null
          plan?: Database["public"]["Enums"]["user_plan"]
          role?: Database["public"]["Enums"]["user_role"]
          timezone?: string
          trial_expires_at?: string | null
          trial_plan?: string | null
          trial_started_at?: string | null
          updated_at?: string
          usage_reset_at?: string
        }
        Update: {
          ai_advice_used?: number
          ai_queries_used?: number
          avatar_url?: string | null
          billing_plan?: string
          billing_provider_customer_id?: string | null
          billing_status?: string
          bio?: string | null
          business_name?: string | null
          created_at?: string
          currency?: string
          date_format?: string
          exports_used?: number
          id?: string
          insights_reset_at?: string
          insights_used?: number
          language?: string
          last_name?: string | null
          locality?: string | null
          name?: string | null
          overstock_threshold?: number | null
          phone?: string | null
          plan?: Database["public"]["Enums"]["user_plan"]
          role?: Database["public"]["Enums"]["user_role"]
          timezone?: string
          trial_expires_at?: string | null
          trial_plan?: string | null
          trial_started_at?: string | null
          updated_at?: string
          usage_reset_at?: string
        }
        Relationships: []
      }
      purchase_items: {
        Row: {
          account_id: string | null
          id: string
          price: number
          product_id: string | null
          purchase_id: string
          quantity: number
          subtotal: number
          unit_id: string | null
          variant_id: string | null
        }
        Insert: {
          account_id?: string | null
          id?: string
          price?: number
          product_id?: string | null
          purchase_id: string
          quantity?: number
          subtotal?: number
          unit_id?: string | null
          variant_id?: string | null
        }
        Update: {
          account_id?: string | null
          id?: string
          price?: number
          product_id?: string | null
          purchase_id?: string
          quantity?: number
          subtotal?: number
          unit_id?: string | null
          variant_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "purchase_items_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_items_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "v_products_with_stock"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_items_purchase_id_fkey"
            columns: ["purchase_id"]
            isOneToOne: false
            referencedRelation: "purchases"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_items_purchase_id_fkey"
            columns: ["purchase_id"]
            isOneToOne: false
            referencedRelation: "v_purchases_flat"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_items_unit_id_fkey"
            columns: ["unit_id"]
            isOneToOne: false
            referencedRelation: "units_of_measure"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_items_variant_id_fkey"
            columns: ["variant_id"]
            isOneToOne: false
            referencedRelation: "product_variants"
            referencedColumns: ["id"]
          },
        ]
      }
      purchases: {
        Row: {
          account_id: string | null
          amount: number
          branch_id: string | null
          company_id: string | null
          created_at: string
          date: string
          description: string | null
          id: string
          operation_id: string | null
          product_id: string | null
          quantity: number
          supplier_id: string | null
          total: number | null
          unit_id: string | null
          user_id: string
        }
        Insert: {
          account_id?: string | null
          amount: number
          branch_id?: string | null
          company_id?: string | null
          created_at?: string
          date?: string
          description?: string | null
          id?: string
          operation_id?: string | null
          product_id?: string | null
          quantity?: number
          supplier_id?: string | null
          total?: number | null
          unit_id?: string | null
          user_id?: string
        }
        Update: {
          account_id?: string | null
          amount?: number
          branch_id?: string | null
          company_id?: string | null
          created_at?: string
          date?: string
          description?: string | null
          id?: string
          operation_id?: string | null
          product_id?: string | null
          quantity?: number
          supplier_id?: string | null
          total?: number | null
          unit_id?: string | null
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "purchases_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchases_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchases_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchases_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchases_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "v_products_with_stock"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchases_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchases_unit_id_fkey"
            columns: ["unit_id"]
            isOneToOne: false
            referencedRelation: "units_of_measure"
            referencedColumns: ["id"]
          },
        ]
      }
      sale_items: {
        Row: {
          account_id: string | null
          id: string
          price: number
          product_id: string | null
          quantity: number
          sale_id: string
          subtotal: number
          unit_id: string | null
          variant_id: string | null
        }
        Insert: {
          account_id?: string | null
          id?: string
          price?: number
          product_id?: string | null
          quantity?: number
          sale_id: string
          subtotal?: number
          unit_id?: string | null
          variant_id?: string | null
        }
        Update: {
          account_id?: string | null
          id?: string
          price?: number
          product_id?: string | null
          quantity?: number
          sale_id?: string
          subtotal?: number
          unit_id?: string | null
          variant_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "sale_items_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sale_items_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "v_products_with_stock"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sale_items_sale_id_fkey"
            columns: ["sale_id"]
            isOneToOne: false
            referencedRelation: "sales"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sale_items_sale_id_fkey"
            columns: ["sale_id"]
            isOneToOne: false
            referencedRelation: "v_sales_flat"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sale_items_unit_id_fkey"
            columns: ["unit_id"]
            isOneToOne: false
            referencedRelation: "units_of_measure"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sale_items_variant_id_fkey"
            columns: ["variant_id"]
            isOneToOne: false
            referencedRelation: "product_variants"
            referencedColumns: ["id"]
          },
        ]
      }
      sale_notifications: {
        Row: {
          channel: string
          client_id: string | null
          created_at: string | null
          error_message: string | null
          id: string
          operation_id: string
          phone_used: string | null
          provider_message_id: string | null
          sent_at: string | null
          status: string
          user_id: string
        }
        Insert: {
          channel?: string
          client_id?: string | null
          created_at?: string | null
          error_message?: string | null
          id?: string
          operation_id: string
          phone_used?: string | null
          provider_message_id?: string | null
          sent_at?: string | null
          status?: string
          user_id: string
        }
        Update: {
          channel?: string
          client_id?: string | null
          created_at?: string | null
          error_message?: string | null
          id?: string
          operation_id?: string
          phone_used?: string | null
          provider_message_id?: string | null
          sent_at?: string | null
          status?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "sale_notifications_client_id_fkey"
            columns: ["client_id"]
            isOneToOne: false
            referencedRelation: "clients"
            referencedColumns: ["id"]
          },
        ]
      }
      sales: {
        Row: {
          account_id: string | null
          amount: number
          branch_id: string | null
          canal: string | null
          client_id: string | null
          company_id: string | null
          created_at: string
          currency: string
          date: string
          id: string
          operation_id: string | null
          product_id: string | null
          quantity: number
          total: number | null
          unit_id: string | null
          user_id: string
        }
        Insert: {
          account_id?: string | null
          amount: number
          branch_id?: string | null
          canal?: string | null
          client_id?: string | null
          company_id?: string | null
          created_at?: string
          currency?: string
          date?: string
          id?: string
          operation_id?: string | null
          product_id?: string | null
          quantity?: number
          total?: number | null
          unit_id?: string | null
          user_id?: string
        }
        Update: {
          account_id?: string | null
          amount?: number
          branch_id?: string | null
          canal?: string | null
          client_id?: string | null
          company_id?: string | null
          created_at?: string
          currency?: string
          date?: string
          id?: string
          operation_id?: string | null
          product_id?: string | null
          quantity?: number
          total?: number | null
          unit_id?: string | null
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "sales_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_client_id_fkey"
            columns: ["client_id"]
            isOneToOne: false
            referencedRelation: "clients"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "v_products_with_stock"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_unit_id_fkey"
            columns: ["unit_id"]
            isOneToOne: false
            referencedRelation: "units_of_measure"
            referencedColumns: ["id"]
          },
        ]
      }
      stock_movements: {
        Row: {
          account_id: string | null
          branch_id: string | null
          created_at: string
          id: string
          metadata: Json | null
          movement_number: number | null
          notes: string | null
          operation_group_id: string | null
          performed_by: string | null
          product_id: string | null
          product_name: string | null
          quantity_after: number | null
          quantity_before: number | null
          quantity_delta: number
          reason: string | null
          reference_id: string | null
          reference_type: string | null
          transfer_id: string | null
          type: string
          user_id: string
        }
        Insert: {
          account_id?: string | null
          branch_id?: string | null
          created_at?: string
          id?: string
          metadata?: Json | null
          movement_number?: number | null
          notes?: string | null
          operation_group_id?: string | null
          performed_by?: string | null
          product_id?: string | null
          product_name?: string | null
          quantity_after?: number | null
          quantity_before?: number | null
          quantity_delta: number
          reason?: string | null
          reference_id?: string | null
          reference_type?: string | null
          transfer_id?: string | null
          type: string
          user_id: string
        }
        Update: {
          account_id?: string | null
          branch_id?: string | null
          created_at?: string
          id?: string
          metadata?: Json | null
          movement_number?: number | null
          notes?: string | null
          operation_group_id?: string | null
          performed_by?: string | null
          product_id?: string | null
          product_name?: string | null
          quantity_after?: number | null
          quantity_before?: number | null
          quantity_delta?: number
          reason?: string | null
          reference_id?: string | null
          reference_type?: string | null
          transfer_id?: string | null
          type?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "stock_movements_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_movements_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_movements_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_movements_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "v_products_with_stock"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_movements_transfer_id_fkey"
            columns: ["transfer_id"]
            isOneToOne: false
            referencedRelation: "stock_transfers"
            referencedColumns: ["id"]
          },
        ]
      }
      stock_transfers: {
        Row: {
          account_id: string
          created_at: string
          created_by: string
          from_branch_id: string
          id: string
          product_id: string
          quantity: number
          status: string
          to_branch_id: string
        }
        Insert: {
          account_id: string
          created_at?: string
          created_by: string
          from_branch_id: string
          id?: string
          product_id: string
          quantity: number
          status?: string
          to_branch_id: string
        }
        Update: {
          account_id?: string
          created_at?: string
          created_by?: string
          from_branch_id?: string
          id?: string
          product_id?: string
          quantity?: number
          status?: string
          to_branch_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "stock_transfers_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_transfers_from_branch_id_fkey"
            columns: ["from_branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_transfers_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_transfers_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "v_products_with_stock"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_transfers_to_branch_id_fkey"
            columns: ["to_branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
        ]
      }
      suppliers: {
        Row: {
          account_id: string | null
          company_id: string
          created_at: string
          email: string | null
          id: string
          name: string
          phone: string | null
          tax_id: string | null
        }
        Insert: {
          account_id?: string | null
          company_id: string
          created_at?: string
          email?: string | null
          id?: string
          name: string
          phone?: string | null
          tax_id?: string | null
        }
        Update: {
          account_id?: string | null
          company_id?: string
          created_at?: string
          email?: string | null
          id?: string
          name?: string
          phone?: string | null
          tax_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "suppliers_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "suppliers_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
        ]
      }
      units_of_measure: {
        Row: {
          account_id: string | null
          base_unit_id: string | null
          created_at: string
          factor: number
          id: string
          is_system: boolean
          name: string
          symbol: string
          type: string
          user_id: string | null
        }
        Insert: {
          account_id?: string | null
          base_unit_id?: string | null
          created_at?: string
          factor?: number
          id?: string
          is_system?: boolean
          name: string
          symbol: string
          type: string
          user_id?: string | null
        }
        Update: {
          account_id?: string | null
          base_unit_id?: string | null
          created_at?: string
          factor?: number
          id?: string
          is_system?: boolean
          name?: string
          symbol?: string
          type?: string
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "units_of_measure_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "units_of_measure_base_unit_id_fkey"
            columns: ["base_unit_id"]
            isOneToOne: false
            referencedRelation: "units_of_measure"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      profiles_public: {
        Row: {
          id: string | null
          name: string | null
        }
        Insert: {
          id?: string | null
          name?: string | null
        }
        Update: {
          id?: string | null
          name?: string | null
        }
        Relationships: []
      }
      v_products_with_stock: {
        Row: {
          account_id: string | null
          barcode: string | null
          category: string | null
          company_id: string | null
          cost: number | null
          created_at: string | null
          deleted_at: string | null
          id: string | null
          is_variant: boolean | null
          min_stock: number | null
          name: string | null
          parent_id: string | null
          price: number | null
          sku: string | null
          stock: number | null
          stock_control_type: string | null
          user_id: string | null
        }
        Insert: {
          account_id?: string | null
          barcode?: string | null
          category?: string | null
          company_id?: string | null
          cost?: number | null
          created_at?: string | null
          deleted_at?: string | null
          id?: string | null
          is_variant?: boolean | null
          min_stock?: number | null
          name?: string | null
          parent_id?: string | null
          price?: number | null
          sku?: string | null
          stock?: never
          stock_control_type?: string | null
          user_id?: string | null
        }
        Update: {
          account_id?: string | null
          barcode?: string | null
          category?: string | null
          company_id?: string | null
          cost?: number | null
          created_at?: string | null
          deleted_at?: string | null
          id?: string | null
          is_variant?: boolean | null
          min_stock?: number | null
          name?: string | null
          parent_id?: string | null
          price?: number | null
          sku?: string | null
          stock?: never
          stock_control_type?: string | null
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "products_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "products_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "products_parent_id_fkey"
            columns: ["parent_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "products_parent_id_fkey"
            columns: ["parent_id"]
            isOneToOne: false
            referencedRelation: "v_products_with_stock"
            referencedColumns: ["id"]
          },
        ]
      }
      v_purchases_flat: {
        Row: {
          account_id: string | null
          amount: number | null
          date: string | null
          description: string | null
          id: string | null
          operation_id: string | null
          product_id: string | null
          quantity: number | null
          total: number | null
          unit_id: string | null
          user_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "purchases_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
        ]
      }
      v_sales_flat: {
        Row: {
          account_id: string | null
          amount: number | null
          branch_id: string | null
          canal: string | null
          client_id: string | null
          currency: string | null
          date: string | null
          id: string | null
          operation_id: string | null
          product_id: string | null
          quantity: number | null
          total: number | null
          unit_id: string | null
          user_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "sales_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_client_id_fkey"
            columns: ["client_id"]
            isOneToOne: false
            referencedRelation: "clients"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Functions: {
      c21_apply_branch_stock_delta: {
        Args: {
          p_account_id: string
          p_branch_id: string
          p_delta: number
          p_product_id: string
        }
        Returns: undefined
      }
      c26_default_branch: { Args: { p_account_id: string }; Returns: string }
      current_account_ids: { Args: never; Returns: string[] }
      expire_trials: { Args: never; Returns: number }
      get_account_ids_for_user: {
        Args: { p_user_id: string }
        Returns: string[]
      }
      get_admin_activation_rate: {
        Args: { p_date_from: string; p_date_to: string }
        Returns: number
      }
      get_admin_community_interactions: {
        Args: { p_date_from: string; p_date_to: string }
        Returns: number
      }
      get_admin_insights_breakdown: {
        Args: { p_date_from: string; p_date_to: string }
        Returns: {
          insight_type: string
          total: number
        }[]
      }
      get_admin_paid_conversion_rate: { Args: never; Returns: number }
      get_admin_umv_rate: {
        Args: { p_date_from: string; p_date_to: string }
        Returns: number
      }
      get_dashboard_critical_stock:
        | { Args: never; Returns: number }
        | { Args: { p_user_id: string }; Returns: number }
      get_dashboard_financials: {
        Args: { p_branch_id?: string; p_date_from: string; p_date_to: string }
        Returns: {
          net_profit: number
          total_expenses: number
          total_income: number
          total_purchases: number
        }[]
      }
      is_account_writer: { Args: { p_account_id: string }; Returns: boolean }
      is_admin:
        | { Args: never; Returns: boolean }
        | { Args: { uid: string }; Returns: boolean }
      process_cancellations: { Args: never; Returns: number }
      queue_trial_notifications: { Args: never; Returns: number }
      rpc_accept_invitation: { Args: { p_token: string }; Returns: Json }
      rpc_adjust_branch_stock: {
        Args: {
          p_branch_id: string
          p_new_quantity: number
          p_product_id: string
          p_reason?: string
        }
        Returns: Json
      }
      rpc_admin_business_kpis: {
        Args: { date_from?: string; date_to?: string }
        Returns: Json
      }
      rpc_admin_kpi_overview: {
        Args: { date_from: string; date_to: string; granularity?: string }
        Returns: Json
      }
      rpc_admin_module_stats: {
        Args: { p_date_from: string; p_date_to: string; p_module_type: string }
        Returns: Json
      }
      rpc_admin_retention_30d: {
        Args: {
          cohort_granularity?: string
          date_from?: string
          date_to?: string
        }
        Returns: {
          cohort_size: number
          cohort_start: string
          retained_30d: number
          retention_rate: number
        }[]
      }
      rpc_admin_weekly_usage_distribution: {
        Args: { date_from: string; date_to: string }
        Returns: {
          active_days: number
          users_count: number
          week_start: string
        }[]
      }
      rpc_apply_product_stock_delta: {
        Args: {
          p_allow_negative?: boolean
          p_branch_id?: string
          p_delta: number
          p_log_movement?: boolean
          p_product_id: string
          p_reason?: string
        }
        Returns: Json
      }
      rpc_atomic_log_ai_insight: {
        Args: { p_content: string; p_source_function: string; p_type: string }
        Returns: Json
      }
      rpc_atomic_update_purchase_operation: {
        Args: {
          p_date: string
          p_description: string
          p_items: Json
          p_purchase_ids: string[]
        }
        Returns: Json
      }
      rpc_atomic_update_sale_operation: {
        Args: {
          p_client_id: string
          p_currency: string
          p_date: string
          p_items: Json
          p_sale_ids: string[]
        }
        Returns: Json
      }
      rpc_branch_report: {
        Args: { p_account_id: string; p_end: string; p_start: string }
        Returns: {
          branch_id: string
          branch_name: string
          operation_count: number
          total_expenses: number
          total_sales: number
        }[]
      }
      rpc_bulk_upsert_products: {
        Args: { p_rows: Json; p_user_id: string }
        Returns: Json
      }
      rpc_change_member_role: {
        Args: {
          p_account_id: string
          p_new_role: string
          p_target_user_id: string
        }
        Returns: Json
      }
      rpc_close_branch: { Args: { p_branch_id: string }; Returns: Json }
      rpc_create_branch: {
        Args: { p_account_id: string; p_address?: string; p_name: string }
        Returns: {
          account_id: string
          address: string | null
          closed_at: string | null
          created_at: string
          id: string
          is_active: boolean
          name: string
          opened_at: string | null
          status: string
        }
        SetofOptions: {
          from: "*"
          to: "branches"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      rpc_create_purchase_operation: {
        Args: {
          p_date: string
          p_description: string
          p_idempotency_key: string
          p_items: Json
        }
        Returns: Json
      }
      rpc_create_purchase_operation_v2: {
        Args: {
          p_date: string
          p_description: string
          p_idempotency_key: string
          p_items: Json
        }
        Returns: Json
      }
      rpc_create_sale_operation: {
        Args: {
          p_branch_id?: string
          p_canal?: string
          p_client_id: string
          p_currency: string
          p_date: string
          p_idempotency_key: string
          p_items: Json
        }
        Returns: Json
      }
      rpc_create_sale_operation_v2: {
        Args: {
          p_branch_id?: string
          p_canal?: string
          p_client_id: string
          p_currency: string
          p_date: string
          p_idempotency_key: string
          p_items: Json
        }
        Returns: Json
      }
      rpc_dashboard_channel_margin: {
        Args: {
          p_branch_id?: string
          p_from: string
          p_prev_from: string
          p_prev_to: string
          p_to: string
        }
        Returns: {
          channels: Json
          leader: string
          margin_pct: number
          prev_margin_pct: number
        }[]
      }
      rpc_dashboard_kpi_summary: {
        Args: {
          p_branch_id?: string
          p_from: string
          p_prev_from: string
          p_prev_to: string
          p_to: string
        }
        Returns: {
          avg_ticket: number
          cost_per_sale: number
          net_profit: number
          prev_avg_ticket: number
          prev_cost_per_sale: number
          prev_net_profit: number
          prev_sales_count: number
          prev_stagnant_stock_count: number
          prev_stagnant_stock_value: number
          sales_count: number
          stagnant_stock_count: number
          stagnant_stock_value: number
        }[]
      }
      rpc_deactivate_branch: {
        Args: { p_branch_id: string }
        Returns: undefined
      }
      rpc_emit_pending_cae: {
        Args: {
          p_client_id?: string
          p_comprobante_type: string
          p_point_of_sale_id?: string
          p_total: number
        }
        Returns: Json
      }
      rpc_increment_ai_usage: {
        Args: { p_counter: string; p_user_id: string }
        Returns: undefined
      }
      rpc_increment_export_usage: {
        Args: { p_user_id: string }
        Returns: undefined
      }
      rpc_invite_member:
        | { Args: { p_account_id: string; p_email: string }; Returns: Json }
        | {
            Args: { p_account_id: string; p_email: string; p_role?: string }
            Returns: Json
          }
      rpc_my_account_role: { Args: { p_account_id: string }; Returns: string }
      rpc_next_document_number: {
        Args: { p_comprobante_type: string; p_point_of_sale_id: string }
        Returns: number
      }
      rpc_open_branch: { Args: { p_branch_id: string }; Returns: Json }
      rpc_period_comparison: {
        Args: {
          p_a_end: string
          p_a_start: string
          p_b_end: string
          p_b_start: string
        }
        Returns: {
          expenses_delta_pct: number
          operations_delta_pct: number
          period_a_expenses: number
          period_a_operations: number
          period_a_purchases: number
          period_a_revenue: number
          period_b_expenses: number
          period_b_operations: number
          period_b_purchases: number
          period_b_revenue: number
          purchases_delta_pct: number
          revenue_delta_pct: number
        }[]
      }
      rpc_product_profitability: {
        Args: { p_period_days?: number }
        Returns: {
          gross_margin: number
          gross_margin_pct: number
          last_sale_date: string
          product_id: string
          product_name: string
          total_cost: number
          total_revenue: number
          units_sold: number
        }[]
      }
      rpc_remove_member: {
        Args: { p_account_id: string; p_target_user_id: string }
        Returns: Json
      }
      rpc_safe_delete_product:
        | { Args: { p_product_id: string }; Returns: undefined }
        | {
            Args: { p_product_id: string; p_user_id: string }
            Returns: undefined
          }
      rpc_stock_adjustment: {
        Args: {
          p_notes?: string
          p_product_id: string
          p_quantity_delta?: number
          p_reason?: string
          p_reference_id?: string
          p_target_quantity?: number
          p_type?: string
        }
        Returns: Json
      }
      rpc_transfer_stock: {
        Args: {
          p_from_branch_id: string
          p_product_id: string
          p_quantity: number
          p_to_branch_id: string
        }
        Returns: Json
      }
    }
    Enums: {
      user_plan: "free" | "pro"
      user_role: "user" | "admin"
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
  community: {
    Enums: {},
  },
  public: {
    Enums: {
      user_plan: ["free", "pro"],
      user_role: ["user", "admin"],
    },
  },
} as const
