defmodule Roki.Repo.Migrations.ReaderSchemaVerbatim do
  @moduledoc """
  The manga reader's own tables, exactly as they stand in the app this reader came from — same
  names, same columns, same indexes.

  This replaces a tidier set of tables that were here first. The tidier ones were a mistake: the
  reader's library, views, controller and templates all address a series as `(source, slug)` and
  a person as `user_id`, so renaming those columns meant its modules could not be copied, only
  rewritten by hand — and a hand-rewrite of that much code is where an interface someone spent a
  long time getting right quietly turns into something else. Copying it needs its shape.
  """
  use Ecto.Migration

  def up do
    # The tables this app invented for manga are gone: the reader's own modules are copied in
    # verbatim, and they query its tables by its column names. Keeping a tidier shape here would
    # have meant rewriting 3,641 lines of its library by hand, which is how differences creep in.
    for table <- ~w(roki_manga_category_members roki_manga_library roki_manga_categories
                    roki_manga_reads roki_manga_reading roki_manga_events roki_manga_marks
                    roki_manga_annotations roki_manga_page_overrides roki_manga_tiers
                    roki_manga_grid roki_manga_mal roki_manga_arcs roki_manga_titles) do
      execute("drop table if exists #{table} cascade")
    end

    execute(~S"""
    CREATE TABLE public.chapter_page_overrides (
        id bigint NOT NULL,
        user_id uuid NOT NULL,
        source character varying(255) NOT NULL,
        slug character varying(255) NOT NULL,
        chapter character varying(255) NOT NULL,
        page_index integer NOT NULL,
        kind character varying(255) NOT NULL,
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL
    )
    """)

    execute(~S"""
    CREATE SEQUENCE public.chapter_page_overrides_id_seq
        START WITH 1
        INCREMENT BY 1
        NO MINVALUE
        NO MAXVALUE
        CACHE 1
    """)

    execute(~S"""
    ALTER SEQUENCE public.chapter_page_overrides_id_seq OWNED BY public.chapter_page_overrides.id
    """)

    execute(~S"""
    CREATE TABLE public.chapter_reads (
        id bigint NOT NULL,
        user_id uuid NOT NULL,
        source character varying(255) NOT NULL,
        slug character varying(255) NOT NULL,
        chapter character varying(255) NOT NULL,
        read_at timestamp without time zone NOT NULL,
        seconds integer DEFAULT 0 NOT NULL,
        total_pages integer
    )
    """)

    execute(~S"""
    CREATE SEQUENCE public.chapter_reads_id_seq
        START WITH 1
        INCREMENT BY 1
        NO MINVALUE
        NO MAXVALUE
        CACHE 1
    """)

    execute(~S"""
    ALTER SEQUENCE public.chapter_reads_id_seq OWNED BY public.chapter_reads.id
    """)

    execute(~S"""
    CREATE TABLE public.library_events (
        id bigint NOT NULL,
        user_id uuid NOT NULL,
        source character varying(255) NOT NULL,
        slug character varying(255) NOT NULL,
        event character varying(255) NOT NULL,
        chapter character varying(255),
        happened_at timestamp without time zone NOT NULL
    )
    """)

    execute(~S"""
    CREATE SEQUENCE public.library_events_id_seq
        START WITH 1
        INCREMENT BY 1
        NO MINVALUE
        NO MAXVALUE
        CACHE 1
    """)

    execute(~S"""
    ALTER SEQUENCE public.library_events_id_seq OWNED BY public.library_events.id
    """)

    execute(~S"""
    CREATE TABLE public.manga_annotations (
        id bigint NOT NULL,
        comment_uuid uuid NOT NULL,
        user_id uuid NOT NULL,
        source character varying(255) NOT NULL,
        slug character varying(255) NOT NULL,
        chapter character varying(255) NOT NULL,
        page integer NOT NULL,
        title character varying(255) NOT NULL,
        x_pct double precision NOT NULL,
        y_pct double precision NOT NULL,
        w_pct double precision NOT NULL,
        h_pct double precision NOT NULL,
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL,
        color character varying(255) DEFAULT 'blue'::character varying NOT NULL,
        visibility character varying(255) DEFAULT 'public'::character varying NOT NULL,
        CONSTRAINT visibility_must_be_valid CHECK (((visibility)::text = ANY (ARRAY[('public'::character varying)::text, ('private'::character varying)::text])))
    )
    """)

    execute(~S"""
    CREATE SEQUENCE public.manga_annotations_id_seq
        START WITH 1
        INCREMENT BY 1
        NO MINVALUE
        NO MAXVALUE
        CACHE 1
    """)

    execute(~S"""
    ALTER SEQUENCE public.manga_annotations_id_seq OWNED BY public.manga_annotations.id
    """)

    execute(~S"""
    CREATE TABLE public.manga_categories (
        id bigint NOT NULL,
        user_id uuid NOT NULL,
        name character varying(255) NOT NULL,
        "position" integer DEFAULT 0 NOT NULL,
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL
    )
    """)

    execute(~S"""
    CREATE SEQUENCE public.manga_categories_id_seq
        START WITH 1
        INCREMENT BY 1
        NO MINVALUE
        NO MAXVALUE
        CACHE 1
    """)

    execute(~S"""
    ALTER SEQUENCE public.manga_categories_id_seq OWNED BY public.manga_categories.id
    """)

    execute(~S"""
    CREATE TABLE public.manga_category_memberships (
        id bigint NOT NULL,
        saved_manga_id bigint NOT NULL,
        category_id bigint NOT NULL,
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL
    )
    """)

    execute(~S"""
    CREATE SEQUENCE public.manga_category_memberships_id_seq
        START WITH 1
        INCREMENT BY 1
        NO MINVALUE
        NO MAXVALUE
        CACHE 1
    """)

    execute(~S"""
    ALTER SEQUENCE public.manga_category_memberships_id_seq OWNED BY public.manga_category_memberships.id
    """)

    execute(~S"""
    CREATE TABLE public.manga_grid_slots (
        id bigint NOT NULL,
        user_id uuid NOT NULL,
        slot integer NOT NULL,
        label character varying(255) NOT NULL,
        source character varying(255),
        slug character varying(255),
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL,
        mode character varying(255) DEFAULT 'overall'::character varying NOT NULL
    )
    """)

    execute(~S"""
    CREATE SEQUENCE public.manga_grid_slots_id_seq
        START WITH 1
        INCREMENT BY 1
        NO MINVALUE
        NO MAXVALUE
        CACHE 1
    """)

    execute(~S"""
    ALTER SEQUENCE public.manga_grid_slots_id_seq OWNED BY public.manga_grid_slots.id
    """)

    execute(~S"""
    CREATE TABLE public.manga_mal_links (
        id bigint NOT NULL,
        user_id uuid NOT NULL,
        source character varying(255) NOT NULL,
        slug character varying(255) NOT NULL,
        mal_id integer NOT NULL,
        data jsonb DEFAULT '{}'::jsonb NOT NULL,
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL
    )
    """)

    execute(~S"""
    CREATE SEQUENCE public.manga_mal_links_id_seq
        START WITH 1
        INCREMENT BY 1
        NO MINVALUE
        NO MAXVALUE
        CACHE 1
    """)

    execute(~S"""
    ALTER SEQUENCE public.manga_mal_links_id_seq OWNED BY public.manga_mal_links.id
    """)

    execute(~S"""
    CREATE TABLE public.manga_marks (
        id bigint NOT NULL,
        user_id uuid NOT NULL,
        source character varying(255) NOT NULL,
        slug character varying(255) NOT NULL,
        chapter character varying(255) NOT NULL,
        items jsonb DEFAULT '[]'::jsonb NOT NULL,
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL
    )
    """)

    execute(~S"""
    CREATE SEQUENCE public.manga_marks_id_seq
        START WITH 1
        INCREMENT BY 1
        NO MINVALUE
        NO MAXVALUE
        CACHE 1
    """)

    execute(~S"""
    ALTER SEQUENCE public.manga_marks_id_seq OWNED BY public.manga_marks.id
    """)

    execute(~S"""
    CREATE TABLE public.manga_metadata (
        id bigint NOT NULL,
        source character varying(255) NOT NULL,
        slug character varying(255) NOT NULL,
        cover_file_uuid uuid,
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL,
        data jsonb DEFAULT '{}'::jsonb
    )
    """)

    execute(~S"""
    CREATE SEQUENCE public.manga_metadata_id_seq
        START WITH 1
        INCREMENT BY 1
        NO MINVALUE
        NO MAXVALUE
        CACHE 1
    """)

    execute(~S"""
    ALTER SEQUENCE public.manga_metadata_id_seq OWNED BY public.manga_metadata.id
    """)

    execute(~S"""
    CREATE TABLE public.manga_story_data (
        id bigint NOT NULL,
        source character varying(255) NOT NULL,
        slug character varying(255) NOT NULL,
        story_slug character varying(255),
        story jsonb DEFAULT '{}'::jsonb NOT NULL,
        arcs jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
        units jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
        synced_at timestamp(0) without time zone NOT NULL,
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL,
        volumes jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL
    )
    """)

    execute(~S"""
    CREATE SEQUENCE public.manga_story_data_id_seq
        START WITH 1
        INCREMENT BY 1
        NO MINVALUE
        NO MAXVALUE
        CACHE 1
    """)

    execute(~S"""
    ALTER SEQUENCE public.manga_story_data_id_seq OWNED BY public.manga_story_data.id
    """)

    execute(~S"""
    CREATE TABLE public.manga_tierlist (
        id bigint NOT NULL,
        user_id uuid NOT NULL,
        source character varying(255) NOT NULL,
        slug character varying(255) NOT NULL,
        tier character varying(255) NOT NULL,
        "position" integer DEFAULT 0 NOT NULL,
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL
    )
    """)

    execute(~S"""
    CREATE SEQUENCE public.manga_tierlist_id_seq
        START WITH 1
        INCREMENT BY 1
        NO MINVALUE
        NO MAXVALUE
        CACHE 1
    """)

    execute(~S"""
    ALTER SEQUENCE public.manga_tierlist_id_seq OWNED BY public.manga_tierlist.id
    """)

    execute(~S"""
    CREATE TABLE public.manga_tracker_tokens (
        id bigint NOT NULL,
        user_id uuid NOT NULL,
        provider character varying(255) NOT NULL,
        access_token text NOT NULL,
        refresh_token text,
        expires_at timestamp without time zone,
        remote_username character varying(255),
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL
    )
    """)

    execute(~S"""
    CREATE SEQUENCE public.manga_tracker_tokens_id_seq
        START WITH 1
        INCREMENT BY 1
        NO MINVALUE
        NO MAXVALUE
        CACHE 1
    """)

    execute(~S"""
    ALTER SEQUENCE public.manga_tracker_tokens_id_seq OWNED BY public.manga_tracker_tokens.id
    """)

    execute(~S"""
    CREATE TABLE public.reading_activity (
        id bigint NOT NULL,
        user_id uuid NOT NULL,
        date date NOT NULL,
        reading_seconds integer DEFAULT 0 NOT NULL,
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL,
        source character varying(255),
        slug character varying(255),
        title character varying(255),
        hour integer DEFAULT 0 NOT NULL,
        chapters_read integer DEFAULT 0 NOT NULL
    )
    """)

    execute(~S"""
    CREATE SEQUENCE public.reading_activity_id_seq
        START WITH 1
        INCREMENT BY 1
        NO MINVALUE
        NO MAXVALUE
        CACHE 1
    """)

    execute(~S"""
    ALTER SEQUENCE public.reading_activity_id_seq OWNED BY public.reading_activity.id
    """)

    execute(~S"""
    CREATE TABLE public.saved_manga (
        id bigint NOT NULL,
        user_id uuid,
        source character varying(255) DEFAULT 'mangafreak'::character varying NOT NULL,
        slug character varying(255) NOT NULL,
        title character varying(255) NOT NULL,
        cover_url character varying(255) NOT NULL,
        reading_mode character varying(255) DEFAULT 'scroll'::character varying NOT NULL,
        last_chapter character varying(255),
        last_page integer,
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL,
        reading_seconds integer DEFAULT 0 NOT NULL,
        comments_visible boolean DEFAULT false NOT NULL,
        category_id bigint,
        total_chapters integer,
        reading_mode_desktop character varying(255),
        reading_mode_mobile character varying(255),
        tap_zone_preset character varying(255) DEFAULT 'default'::character varying NOT NULL,
        tap_zone_preset_desktop character varying(255),
        tap_zone_preset_mobile character varying(255),
        reading_direction character varying(255) DEFAULT 'rtl'::character varying,
        reading_seconds_adjusted integer,
        chapter_seconds integer DEFAULT 0 NOT NULL,
        max_chapter character varying(255),
        visiting_chapter character varying(255),
        visiting_seconds integer DEFAULT 0,
        chapter_near_end boolean DEFAULT false,
        prev_chapter character varying(255),
        prev_chapter_seconds integer DEFAULT 0,
        prev_chapter_near_end boolean DEFAULT false,
        smart_crop boolean DEFAULT false,
        cover_file_uuid uuid,
        completed boolean DEFAULT false NOT NULL,
        last_page_fraction double precision DEFAULT 0.0 NOT NULL,
        reading_rotation integer DEFAULT 0 NOT NULL,
        last_chapter_total_pages integer,
        last_chapter_number integer,
        reading_seconds_offsite integer,
        reading_seconds_offsite_approximate boolean DEFAULT false NOT NULL,
        newest_chapter_at timestamp(0) without time zone
    )
    """)

    execute(~S"""
    CREATE SEQUENCE public.saved_manga_id_seq
        START WITH 1
        INCREMENT BY 1
        NO MINVALUE
        NO MAXVALUE
        CACHE 1
    """)

    execute(~S"""
    ALTER SEQUENCE public.saved_manga_id_seq OWNED BY public.saved_manga.id
    """)

    execute(~S"""
    ALTER TABLE ONLY public.chapter_page_overrides
        ADD CONSTRAINT chapter_page_overrides_pkey PRIMARY KEY (id)
    """)

    execute(~S"""
    ALTER TABLE ONLY public.chapter_reads
        ADD CONSTRAINT chapter_reads_pkey PRIMARY KEY (id)
    """)

    execute(~S"""
    ALTER TABLE ONLY public.library_events
        ADD CONSTRAINT library_events_pkey PRIMARY KEY (id)
    """)

    execute(~S"""
    ALTER TABLE ONLY public.manga_annotations
        ADD CONSTRAINT manga_annotations_pkey PRIMARY KEY (id)
    """)

    execute(~S"""
    ALTER TABLE ONLY public.manga_categories
        ADD CONSTRAINT manga_categories_pkey PRIMARY KEY (id)
    """)

    execute(~S"""
    ALTER TABLE ONLY public.manga_category_memberships
        ADD CONSTRAINT manga_category_memberships_pkey PRIMARY KEY (id)
    """)

    execute(~S"""
    ALTER TABLE ONLY public.manga_grid_slots
        ADD CONSTRAINT manga_grid_slots_pkey PRIMARY KEY (id)
    """)

    execute(~S"""
    ALTER TABLE ONLY public.manga_mal_links
        ADD CONSTRAINT manga_mal_links_pkey PRIMARY KEY (id)
    """)

    execute(~S"""
    ALTER TABLE ONLY public.manga_marks
        ADD CONSTRAINT manga_marks_pkey PRIMARY KEY (id)
    """)

    execute(~S"""
    ALTER TABLE ONLY public.manga_metadata
        ADD CONSTRAINT manga_metadata_pkey PRIMARY KEY (id)
    """)

    execute(~S"""
    ALTER TABLE ONLY public.manga_story_data
        ADD CONSTRAINT manga_story_data_pkey PRIMARY KEY (id)
    """)

    execute(~S"""
    ALTER TABLE ONLY public.manga_tierlist
        ADD CONSTRAINT manga_tierlist_pkey PRIMARY KEY (id)
    """)

    execute(~S"""
    ALTER TABLE ONLY public.manga_tracker_tokens
        ADD CONSTRAINT manga_tracker_tokens_pkey PRIMARY KEY (id)
    """)

    execute(~S"""
    ALTER TABLE ONLY public.reading_activity
        ADD CONSTRAINT reading_activity_pkey PRIMARY KEY (id)
    """)

    execute(~S"""
    ALTER TABLE ONLY public.saved_manga
        ADD CONSTRAINT saved_manga_pkey PRIMARY KEY (id)
    """)

    execute(~S"""
    CREATE UNIQUE INDEX chapter_page_overrides_user_chapter_index_kind_index ON public.chapter_page_overrides USING btree (user_id, source, slug, chapter, page_index, kind)
    """)

    execute(~S"""
    CREATE INDEX chapter_page_overrides_user_id_source_slug_chapter_index ON public.chapter_page_overrides USING btree (user_id, source, slug, chapter)
    """)

    execute(~S"""
    CREATE INDEX chapter_reads_user_id_read_at_index ON public.chapter_reads USING btree (user_id, read_at)
    """)

    execute(~S"""
    CREATE INDEX chapter_reads_user_id_source_slug_index ON public.chapter_reads USING btree (user_id, source, slug)
    """)

    execute(~S"""
    CREATE INDEX library_events_user_id_happened_at_index ON public.library_events USING btree (user_id, happened_at)
    """)

    execute(~S"""
    CREATE INDEX library_events_user_id_source_slug_index ON public.library_events USING btree (user_id, source, slug)
    """)

    execute(~S"""
    CREATE INDEX manga_annotations_comment_uuid_index ON public.manga_annotations USING btree (comment_uuid)
    """)

    execute(~S"""
    CREATE INDEX manga_annotations_source_slug_chapter_index ON public.manga_annotations USING btree (source, slug, chapter)
    """)

    execute(~S"""
    CREATE INDEX manga_categories_user_id_index ON public.manga_categories USING btree (user_id)
    """)

    execute(~S"""
    CREATE UNIQUE INDEX manga_categories_user_id_name_index ON public.manga_categories USING btree (user_id, name)
    """)

    execute(~S"""
    CREATE INDEX manga_category_memberships_category_id_index ON public.manga_category_memberships USING btree (category_id)
    """)

    execute(~S"""
    CREATE UNIQUE INDEX manga_category_memberships_saved_manga_id_category_id_index ON public.manga_category_memberships USING btree (saved_manga_id, category_id)
    """)

    execute(~S"""
    CREATE UNIQUE INDEX manga_grid_slots_user_id_mode_slot_index ON public.manga_grid_slots USING btree (user_id, mode, slot)
    """)

    execute(~S"""
    CREATE INDEX manga_mal_links_user_id_index ON public.manga_mal_links USING btree (user_id)
    """)

    execute(~S"""
    CREATE UNIQUE INDEX manga_mal_links_user_id_source_slug_index ON public.manga_mal_links USING btree (user_id, source, slug)
    """)

    execute(~S"""
    CREATE INDEX manga_marks_source_slug_chapter_index ON public.manga_marks USING btree (source, slug, chapter)
    """)

    execute(~S"""
    CREATE UNIQUE INDEX manga_marks_user_id_source_slug_chapter_index ON public.manga_marks USING btree (user_id, source, slug, chapter)
    """)

    execute(~S"""
    CREATE UNIQUE INDEX manga_metadata_source_slug_index ON public.manga_metadata USING btree (source, slug)
    """)

    execute(~S"""
    CREATE UNIQUE INDEX manga_story_data_source_slug_index ON public.manga_story_data USING btree (source, slug)
    """)

    execute(~S"""
    CREATE UNIQUE INDEX manga_tierlist_user_id_source_slug_index ON public.manga_tierlist USING btree (user_id, source, slug)
    """)

    execute(~S"""
    CREATE INDEX manga_tierlist_user_id_tier_position_index ON public.manga_tierlist USING btree (user_id, tier, "position")
    """)

    execute(~S"""
    CREATE UNIQUE INDEX manga_tracker_tokens_user_id_provider_index ON public.manga_tracker_tokens USING btree (user_id, provider)
    """)

    execute(~S"""
    CREATE UNIQUE INDEX reading_activity_user_id_date_hour_source_slug_index ON public.reading_activity USING btree (user_id, date, hour, source, slug)
    """)

    execute(~S"""
    CREATE INDEX saved_manga_category_id_index ON public.saved_manga USING btree (category_id)
    """)

    execute(~S"""
    CREATE INDEX saved_manga_user_id_index ON public.saved_manga USING btree (user_id)
    """)

    execute(~S"""
    CREATE UNIQUE INDEX saved_manga_user_id_source_slug_index ON public.saved_manga USING btree (user_id, source, slug)
    """)

    execute(~S"""
    ALTER TABLE ONLY public.manga_category_memberships
        ADD CONSTRAINT manga_category_memberships_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.manga_categories(id) ON DELETE CASCADE
    """)

    execute(~S"""
    ALTER TABLE ONLY public.manga_category_memberships
        ADD CONSTRAINT manga_category_memberships_saved_manga_id_fkey FOREIGN KEY (saved_manga_id) REFERENCES public.saved_manga(id) ON DELETE CASCADE
    """)

    execute(~S"""
    ALTER TABLE ONLY public.saved_manga
        ADD CONSTRAINT saved_manga_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.manga_categories(id) ON DELETE SET NULL
    """)

    execute(~S"""
    ALTER TABLE ONLY public.chapter_page_overrides ALTER COLUMN id SET DEFAULT nextval('public.chapter_page_overrides_id_seq'::regclass)
    """)

    execute(~S"""
    ALTER TABLE ONLY public.chapter_reads ALTER COLUMN id SET DEFAULT nextval('public.chapter_reads_id_seq'::regclass)
    """)

    execute(~S"""
    ALTER TABLE ONLY public.library_events ALTER COLUMN id SET DEFAULT nextval('public.library_events_id_seq'::regclass)
    """)

    execute(~S"""
    ALTER TABLE ONLY public.manga_annotations ALTER COLUMN id SET DEFAULT nextval('public.manga_annotations_id_seq'::regclass)
    """)

    execute(~S"""
    ALTER TABLE ONLY public.manga_categories ALTER COLUMN id SET DEFAULT nextval('public.manga_categories_id_seq'::regclass)
    """)

    execute(~S"""
    ALTER TABLE ONLY public.manga_category_memberships ALTER COLUMN id SET DEFAULT nextval('public.manga_category_memberships_id_seq'::regclass)
    """)

    execute(~S"""
    ALTER TABLE ONLY public.manga_grid_slots ALTER COLUMN id SET DEFAULT nextval('public.manga_grid_slots_id_seq'::regclass)
    """)

    execute(~S"""
    ALTER TABLE ONLY public.manga_mal_links ALTER COLUMN id SET DEFAULT nextval('public.manga_mal_links_id_seq'::regclass)
    """)

    execute(~S"""
    ALTER TABLE ONLY public.manga_marks ALTER COLUMN id SET DEFAULT nextval('public.manga_marks_id_seq'::regclass)
    """)

    execute(~S"""
    ALTER TABLE ONLY public.manga_metadata ALTER COLUMN id SET DEFAULT nextval('public.manga_metadata_id_seq'::regclass)
    """)

    execute(~S"""
    ALTER TABLE ONLY public.manga_story_data ALTER COLUMN id SET DEFAULT nextval('public.manga_story_data_id_seq'::regclass)
    """)

    execute(~S"""
    ALTER TABLE ONLY public.manga_tierlist ALTER COLUMN id SET DEFAULT nextval('public.manga_tierlist_id_seq'::regclass)
    """)

    execute(~S"""
    ALTER TABLE ONLY public.manga_tracker_tokens ALTER COLUMN id SET DEFAULT nextval('public.manga_tracker_tokens_id_seq'::regclass)
    """)

    execute(~S"""
    ALTER TABLE ONLY public.reading_activity ALTER COLUMN id SET DEFAULT nextval('public.reading_activity_id_seq'::regclass)
    """)

    execute(~S"""
    ALTER TABLE ONLY public.saved_manga ALTER COLUMN id SET DEFAULT nextval('public.saved_manga_id_seq'::regclass)
    """)
  end

  def down do
    raise "irreversible: this is the schema the reader's own modules are written against"
  end
end
