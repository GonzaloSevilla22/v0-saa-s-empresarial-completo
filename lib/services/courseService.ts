import { createClient } from "@/lib/supabase/client"
import type { Course, CourseModule, CourseLesson } from "@/lib/types"

const supabase = createClient()

export const courseService = {
  /**
   * Fetch all courses with metadata
   */
  async getVisibleCourses() {
    const { data, error } = await supabase
      .from("courses")
      .select("*")
      .order("created_at", { ascending: false })

    if (error) throw error
    return data
  },

  /**
   * Fetch a single course with its modules and lessons
   */
  async getCourseDetail(courseId: string) {
    const { data: course, error: courseError } = await supabase
      .from("courses")
      .select("*")
      .eq("id", courseId)
      .single()

    if (courseError) throw courseError

    const { data: modules, error: modulesError } = await supabase
      .from("course_modules")
      .select(`
        *,
        lessons:course_lessons(*)
      `)
      .eq("course_id", courseId)
      .order("order_index", { ascending: true })

    if (modulesError) throw modulesError

    // Sort lessons within modules by order_index
    const processedModules = modules.map((mod: any) => ({
      ...mod,
      lessons: (mod.lessons || []).sort((a: any, b: any) => a.order_index - b.order_index)
    }))

    return {
      ...course,
      modules: processedModules
    }
  },

  /**
   * Enroll a user in a course
   */
  async enrollUser(userId: string, courseId: string) {
    const { error } = await supabase
      .from("course_enrollments")
      .upsert({ user_id: userId, course_id: courseId })

    if (error) throw error
  },

  /**
   * Check if a user is enrolled in a course
   */
  async isEnrolled(userId: string, courseId: string) {
    const { data, error } = await supabase
      .from("course_enrollments")
      .select("id")
      .eq("user_id", userId)
      .eq("course_id", courseId)
      .maybeSingle()

    if (error) throw error
    return !!data
  },

  /**
   * Update lesson progress
   */
  async updateLessonProgress(userId: string, lessonId: string, completed: boolean) {
    const { error } = await supabase
      .from("lesson_progress")
      .upsert({ 
        user_id: userId, 
        lesson_id: lessonId, 
        completed,
        updated_at: new Date().toISOString()
      }, { onConflict: 'user_id,lesson_id' })

    if (error) throw error
  },

  /**
   * Get user progress for a course
   */
  async getCourseProgress(userId: string, courseId: string) {
    // 1. Get all lesson IDs for the course
    const { data: modules, error: modulesError } = await supabase
      .from("course_modules")
      .select("id")
      .eq("course_id", courseId)
    
    if (modulesError) throw modulesError
    
    const moduleIds = modules.map(m => m.id)
    if (moduleIds.length === 0) return 0

    const { data: lessons, error: lessonsError } = await supabase
      .from("course_lessons")
      .select("id")
      .in("module_id", moduleIds)

    if (lessonsError) throw lessonsError
    
    const lessonIds = lessons.map(l => l.id)
    if (lessonIds.length === 0) return 0

    // 2. Get completed lessons for the user
    const { data: progress, error: progressError } = await supabase
      .from("lesson_progress")
      .select("lesson_id")
      .eq("user_id", userId)
      .eq("completed", true)
      .in("lesson_id", lessonIds)

    if (progressError) throw progressError

    const totalLessons = lessonIds.length
    const completedLessons = progress.length

    return Math.round((completedLessons / totalLessons) * 100)
  }
}
