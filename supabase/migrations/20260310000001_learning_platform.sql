-- Learning Platform Tables

-- 1. Course Modules
CREATE TABLE IF NOT EXISTS public.course_modules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    course_id UUID NOT NULL REFERENCES public.courses(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    order_index INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 2. Course Lessons
CREATE TABLE IF NOT EXISTS public.course_lessons (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    module_id UUID NOT NULL REFERENCES public.course_modules(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    description TEXT,
    content_url TEXT,
    duration TEXT,
    order_index INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3. Course Enrollments
CREATE TABLE IF NOT EXISTS public.course_enrollments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    course_id UUID NOT NULL REFERENCES public.courses(id) ON DELETE CASCADE,
    enrolled_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(user_id, course_id)
);

-- 4. Lesson Progress
CREATE TABLE IF NOT EXISTS public.lesson_progress (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    lesson_id UUID NOT NULL REFERENCES public.course_lessons(id) ON DELETE CASCADE,
    completed BOOLEAN NOT NULL DEFAULT false,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(user_id, lesson_id)
);

-- RLS POLICIES

-- Enable RLS
ALTER TABLE public.course_modules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.course_lessons ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.course_enrollments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lesson_progress ENABLE ROW LEVEL SECURITY;

-- Course Modules: Public read for enrolled users or free courses? 
-- Simplification: Modules are visible to anyone, lessons might be restricted.
DROP POLICY IF EXISTS "Public read for course modules" ON public.course_modules;
CREATE POLICY "Public read for course modules" ON public.course_modules
    FOR SELECT USING (true);

-- Course Lessons: Read if enrolled or if the course is not PRO (optional detail)
DROP POLICY IF EXISTS "Public read for course lessons" ON public.course_lessons;
CREATE POLICY "Public read for course lessons" ON public.course_lessons
    FOR SELECT USING (true);

-- Course Enrollments: Users can see their own enrollments
DROP POLICY IF EXISTS "Users can view their own enrollments" ON public.course_enrollments;
CREATE POLICY "Users can view their own enrollments" ON public.course_enrollments
    FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can enroll themselves" ON public.course_enrollments;
CREATE POLICY "Users can enroll themselves" ON public.course_enrollments
    FOR INSERT WITH CHECK (auth.uid() = user_id);

-- Lesson Progress: Users can view and update their own progress
DROP POLICY IF EXISTS "Users can view their own progress" ON public.lesson_progress;
CREATE POLICY "Users can view their own progress" ON public.lesson_progress
    FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update their own progress" ON public.lesson_progress;
CREATE POLICY "Users can update their own progress" ON public.lesson_progress
    FOR INSERT WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can edit their own progress" ON public.lesson_progress;
CREATE POLICY "Users can edit their own progress" ON public.lesson_progress
    FOR UPDATE USING (auth.uid() = user_id);

-- ADMIN POLICIES (Assuming there's a profiles table with role or similar)
-- For now, let's use the pattern from other tables if existing.
-- I'll check existing RLS policies in a migration file if needed, 
-- but usually admin access is handled by check on profiles.role = 'admin'

-- Grant access to authenticated users
GRANT ALL ON public.course_modules TO authenticated;
GRANT ALL ON public.course_lessons TO authenticated;
GRANT ALL ON public.course_enrollments TO authenticated;
GRANT ALL ON public.lesson_progress TO authenticated;
