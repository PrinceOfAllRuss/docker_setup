-- ============================================
-- TABLES AND INDEXES CREATION SCRIPT
-- For Timetable Back project
-- ============================================

-- Drop tables in reverse order (due to foreign keys)
DROP TABLE IF EXISTS lesson_student_groups CASCADE;
DROP TABLE IF EXISTS day_comments CASCADE;
DROP TABLE IF EXISTS lessons CASCADE;
DROP TABLE IF EXISTS student_groups CASCADE;
DROP TABLE IF EXISTS rooms CASCADE;
DROP TABLE IF EXISTS subjects CASCADE;
DROP TABLE IF EXISTS users CASCADE;

-- Drop triggers if exist
DROP TRIGGER IF EXISTS trg_check_teacher_role ON lessons;
DROP FUNCTION IF EXISTS check_teacher_role();
DROP FUNCTION IF EXISTS has_group_conflict(BIGINT, TIMESTAMP, TIMESTAMP, BIGINT);
DROP FUNCTION IF EXISTS is_room_capacity_sufficient(BIGINT, BIGINT);

-- ============================================
-- TABLE: users
-- ============================================
CREATE TABLE users (
    id BIGSERIAL PRIMARY KEY,
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100) NOT NULL,
    email VARCHAR(255) NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    role VARCHAR(50) NOT NULL,
    phone VARCHAR(20),
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- ============================================
-- TABLE: student_groups
-- ============================================
CREATE TABLE student_groups (
    id BIGSERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    course_year INTEGER NOT NULL CHECK (course_year >= 1 AND course_year <= 6),
    student_count INTEGER NOT NULL CHECK (student_count >= 0),
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- ============================================
-- TABLE: subjects
-- ============================================
CREATE TABLE subjects (
    id BIGSERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    code VARCHAR(20) NOT NULL,
    faculty VARCHAR(100),
    description TEXT,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- ============================================
-- TABLE: rooms
-- ============================================
CREATE TABLE rooms (
    id BIGSERIAL PRIMARY KEY,
    room_number VARCHAR(20) NOT NULL,
    building VARCHAR(100),
    capacity INTEGER NOT NULL CHECK (capacity >= 1),
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- ============================================
-- TABLE: lessons
-- ============================================
CREATE TABLE lessons (
    id BIGSERIAL PRIMARY KEY,
    start_at TIMESTAMP NOT NULL,
    end_at TIMESTAMP NOT NULL,
    room_id BIGINT REFERENCES rooms(id),
    subject_id BIGINT REFERENCES subjects(id),
    teacher_id BIGINT REFERENCES users(id),
    rule_type VARCHAR(20),
    is_override BOOLEAN DEFAULT FALSE,
    is_cancelled BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT check_lessons_time_range CHECK (end_at > start_at)
);

-- ============================================
-- TABLE: day_comments
-- ============================================
CREATE TABLE day_comments (
    id BIGSERIAL PRIMARY KEY,
    date DATE NOT NULL,
    user_id BIGINT REFERENCES users(id),
    comment_text TEXT NOT NULL,
    is_deleted BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- ============================================
-- TABLE: lesson_student_groups (composite primary key)
-- ============================================
CREATE TABLE lesson_student_groups (
    lesson_id BIGINT NOT NULL REFERENCES lessons(id) ON DELETE CASCADE,
    group_id BIGINT NOT NULL REFERENCES student_groups(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (lesson_id, group_id)
);

-- ============================================
-- INDEXES
-- ============================================

-- Indexes for users
CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_role ON users(role);

-- Indexes for student_groups
CREATE INDEX idx_student_groups_name ON student_groups(name);

-- Indexes for subjects
CREATE INDEX idx_subjects_code ON subjects(code);

-- Indexes for rooms
CREATE INDEX idx_rooms_number ON rooms(room_number);
CREATE UNIQUE INDEX idx_rooms_unique ON rooms(room_number, building);

-- Indexes for lessons
CREATE INDEX idx_lessons_time ON lessons(start_at, end_at);
CREATE INDEX idx_lessons_room ON lessons(room_id);
CREATE INDEX idx_lessons_teacher ON lessons(teacher_id);
CREATE INDEX idx_lessons_date ON lessons((start_at::date));

-- Indexes for lesson_student_groups
CREATE INDEX idx_lesson_student_groups_group ON lesson_student_groups(group_id);
CREATE INDEX idx_lesson_student_groups_lesson ON lesson_student_groups(lesson_id);

-- Indexes for day_comments
CREATE INDEX idx_day_comments_date ON day_comments(date);
CREATE INDEX idx_day_comments_user ON day_comments(user_id);

-- ============================================
-- UNIQUE CONSTRAINTS
-- ============================================
ALTER TABLE users ADD CONSTRAINT uk_users_email UNIQUE (email);
ALTER TABLE subjects ADD CONSTRAINT uk_subjects_code UNIQUE (code);

-- ============================================
-- EXCLUSION CONSTRAINTS (requires btree_gist extension)
-- ============================================
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- No room and time conflicts
ALTER TABLE lessons ADD CONSTRAINT no_room_overlap EXCLUDE USING GIST (
    room_id WITH =,
    tsrange(start_at, end_at) WITH &&
) WHERE (is_cancelled = FALSE);

-- No teacher and time conflicts
ALTER TABLE lessons ADD CONSTRAINT no_teacher_overlap EXCLUDE USING GIST (
    teacher_id WITH =,
    tsrange(start_at, end_at) WITH &&
) WHERE (is_cancelled = FALSE AND teacher_id IS NOT NULL);

-- ============================================
-- TRIGGERS
-- ============================================

-- Function to check user role
CREATE OR REPLACE FUNCTION check_teacher_role()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.teacher_id IS NULL THEN
        RETURN NEW;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM users
        WHERE id = NEW.teacher_id
        AND role = 'TEACHER'
    ) THEN
        RAISE EXCEPTION 'User with ID % must have TEACHER role', NEW.teacher_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER trg_check_teacher_role
    AFTER INSERT OR UPDATE ON lessons
    DEFERRABLE INITIALLY IMMEDIATE
    FOR EACH ROW
    EXECUTE FUNCTION check_teacher_role();

-- Function to check group conflict
CREATE OR REPLACE FUNCTION has_group_conflict(
    p_group_id BIGINT,
    p_start_at TIMESTAMP,
    p_end_at TIMESTAMP,
    p_exclude_lesson_id BIGINT DEFAULT NULL
)
RETURNS BOOLEAN AS $$
DECLARE
    conflict_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO conflict_count
    FROM lesson_student_groups lg
    JOIN lessons l ON lg.lesson_id = l.id
    WHERE lg.group_id = p_group_id
      AND l.is_cancelled = FALSE
      AND l.start_at < p_end_at
      AND l.end_at > p_start_at
      AND (p_exclude_lesson_id IS NULL OR l.id != p_exclude_lesson_id);

    RETURN conflict_count > 0;
END;
$$ LANGUAGE plpgsql;

-- Function to check room capacity
CREATE OR REPLACE FUNCTION is_room_capacity_sufficient(
    p_lesson_id BIGINT,
    p_room_id BIGINT
)
RETURNS BOOLEAN AS $$
DECLARE
    total_students INTEGER;
    room_capacity INTEGER;
BEGIN
    SELECT COALESCE(SUM(g.student_count), 0) INTO total_students
    FROM lesson_student_groups lg
    JOIN student_groups g ON lg.group_id = g.id
    WHERE lg.lesson_id = p_lesson_id;

    SELECT capacity INTO room_capacity
    FROM rooms
    WHERE id = p_room_id;

    IF room_capacity IS NULL THEN
        RAISE EXCEPTION 'Room with ID % not found', p_room_id;
    END IF;

    RETURN total_students <= room_capacity;
END;
$$ LANGUAGE plpgsql;
