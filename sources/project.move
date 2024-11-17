module exam_addr::exam_platform {
    use std::string::{Self, String};
    use std::vector;
    use aptos_framework::account;
    use aptos_framework::timestamp;
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::coin::{Self};
    
    // Error codes
    const ENOT_AUTHORIZED: u64 = 1;
    const EEXAM_NOT_FOUND: u64 = 2;
    const EALREADY_REGISTERED: u64 = 3;
    const EEXAM_NOT_STARTED: u64 = 4;
    const EEXAM_ENDED: u64 = 5;
    const ENOT_REGISTERED: u64 = 6;
    const EALREADY_SUBMITTED: u64 = 7;
    const EINVALID_SCORE: u64 = 8;
    const EINSUFFICIENT_VALIDATORS: u64 = 9;

    // Role capabilities
    struct AdminCap has key { }
    struct ExaminerCap has key { }
    struct ValidatorCap has key { }

    // Main structs
    struct Exam has store {
        exam_id: u64,
        title: String,
        content_hash: vector<u8>,
        start_time: u64,
        duration: u64,
        registration_deadline: u64,
        max_participants: u64,
        current_participants: u64,
        minimum_validators: u64,
        examiner: address,
        is_active: bool,
        passing_score: u64,
    }

    struct Registration has store {
        exam_id: u64,
        student: address,
        registered_at: u64,
    }

    struct Submission has store {
        exam_id: u64,
        student: address,
        answers_hash: vector<u8>,
        submitted_at: u64,
        validations: vector<Validation>,
        final_score: Option<u64>,
    }

    struct Validation has store {
        validator: address,
        score: u64,
        timestamp: u64,
    }

    // Events
    struct ExamCreatedEvent has store, drop {
        exam_id: u64,
        examiner: address,
        start_time: u64,
    }

    struct StudentRegisteredEvent has store, drop {
        exam_id: u64,
        student: address,
    }

    struct SubmissionEvent has store, drop {
        exam_id: u64,
        student: address,
        timestamp: u64,
    }

    struct ValidationEvent has store, drop {
        exam_id: u64,
        validator: address,
        student: address,
        score: u64,
    }

    // Platform state
    struct ExamPlatform has key {
        exams: vector<Exam>,
        registrations: vector<Registration>,
        submissions: vector<Submission>,
        exam_counter: u64,
        exam_created_events: EventHandle<ExamCreatedEvent>,
        student_registered_events: EventHandle<StudentRegisteredEvent>,
        submission_events: EventHandle<SubmissionEvent>,
        validation_events: EventHandle<ValidationEvent>,
    }

    // Initialize platform
    public fun initialize(admin: &signer) {
        assert!(signer::address_of(admin) == @exam_addr, ENOT_AUTHORIZED);
        
        move_to(admin, AdminCap {});
        move_to(admin, ExamPlatform {
            exams: vector::empty(),
            registrations: vector::empty(),
            submissions: vector::empty(),
            exam_counter: 0,
            exam_created_events: event::new_event_handle<ExamCreatedEvent>(admin),
            student_registered_events: event::new_event_handle<StudentRegisteredEvent>(admin),
            submission_events: event::new_event_handle<SubmissionEvent>(admin),
            validation_events: event::new_event_handle<ValidationEvent>(admin),
        });
    }

    // Role management
    public fun grant_examiner_role(admin: &signer, examiner_address: address) acquires AdminCap {
        assert!(exists<AdminCap>(signer::address_of(admin)), ENOT_AUTHORIZED);
        move_to(&account::create_signer_with_capability(
            account::create_account_capability(examiner_address)
        ), ExaminerCap {});
    }

    public fun grant_validator_role(admin: &signer, validator_address: address) acquires AdminCap {
        assert!(exists<AdminCap>(signer::address_of(admin)), ENOT_AUTHORIZED);
        move_to(&account::create_signer_with_capability(
            account::create_account_capability(validator_address)
        ), ValidatorCap {});
    }

    // Exam creation
    public fun create_exam(
        examiner: &signer,
        title: String,
        content_hash: vector<u8>,
        start_time: u64,
        duration: u64,
        registration_deadline: u64,
        max_participants: u64,
        minimum_validators: u64,
        passing_score: u64,
    ) acquires ExamPlatform, ExaminerCap {
        let examiner_addr = signer::address_of(examiner);
        assert!(exists<ExaminerCap>(examiner_addr), ENOT_AUTHORIZED);
        
        let platform = borrow_global_mut<ExamPlatform>(@exam_addr);
        let exam_id = platform.exam_counter + 1;
        
        let exam = Exam {
            exam_id,
            title,
            content_hash,
            start_time,
            duration,
            registration_deadline,
            max_participants,
            current_participants: 0,
            minimum_validators,
            examiner: examiner_addr,
            is_active: true,
            passing_score,
        };
        
        vector::push_back(&mut platform.exams, exam);
        platform.exam_counter = exam_id;
        
        event::emit_event(&mut platform.exam_created_events, ExamCreatedEvent {
            exam_id,
            examiner: examiner_addr,
            start_time,
        });
    }

    // Student registration
    public fun register_for_exam(student: &signer, exam_id: u64) acquires ExamPlatform {
        let platform = borrow_global_mut<ExamPlatform>(@exam_addr);
        let exam = get_exam_mut(platform, exam_id);
        let student_addr = signer::address_of(student);
        
        assert!(exam.is_active, EEXAM_NOT_FOUND);
        assert!(timestamp::now_microseconds() <= exam.registration_deadline, EEXAM_ENDED);
        assert!(!is_registered(platform, exam_id, student_addr), EALREADY_REGISTERED);
        assert!(exam.current_participants < exam.max_participants, EEXAM_ENDED);
        
        let registration = Registration {
            exam_id,
            student: student_addr,
            registered_at: timestamp::now_microseconds(),
        };
        
        vector::push_back(&mut platform.registrations, registration);
        exam.current_participants = exam.current_participants + 1;
        
        event::emit_event(&mut platform.student_registered_events, StudentRegisteredEvent {
            exam_id,
            student: student_addr,
        });
    }

    // Submit exam
    public fun submit_exam(
        student: &signer,
        exam_id: u64,
        answers_hash: vector<u8>
    ) acquires ExamPlatform {
        let platform = borrow_global_mut<ExamPlatform>(@exam_addr);
        let exam = get_exam(platform, exam_id);
        let student_addr = signer::address_of(student);
        
        assert!(is_registered(platform, exam_id, student_addr), ENOT_REGISTERED);
        assert!(!has_submitted(platform, exam_id, student_addr), EALREADY_SUBMITTED);
        assert!(timestamp::now_microseconds() >= exam.start_time, EEXAM_NOT_STARTED);
        assert!(timestamp::now_microseconds() <= exam.start_time + exam.duration, EEXAM_ENDED);
        
        let submission = Submission {
            exam_id,
            student: student_addr,
            answers_hash,
            submitted_at: timestamp::now_microseconds(),
            validations: vector::empty(),
            final_score: option::none(),
        };
        
        vector::push_back(&mut platform.submissions, submission);
        
        event::emit_event(&mut platform.submission_events, SubmissionEvent {
            exam_id,
            student: student_addr,
            timestamp: timestamp::now_microseconds(),
        });
    }

    // Validate submission
    public fun validate_submission(
        validator: &signer,
        exam_id: u64,
        student: address,
        score: u64
    ) acquires ExamPlatform, ValidatorCap {
        let validator_addr = signer::address_of(validator);
        assert!(exists<ValidatorCap>(validator_addr), ENOT_AUTHORIZED);
        
        let platform = borrow_global_mut<ExamPlatform>(@exam_addr);
        let exam = get_exam(platform, exam_id);
        let submission = get_submission_mut(platform, exam_id, student);
        
        assert!(timestamp::now_microseconds() > exam.start_time + exam.duration, EEXAM_NOT_STARTED);
        assert!(score <= 100, EINVALID_SCORE);
        
        let validation = Validation {
            validator: validator_addr,
            score,
            timestamp: timestamp::now_microseconds(),
        };
        
        vector::push_back(&mut submission.validations, validation);
        
        if (vector::length(&submission.validations) >= exam.minimum_validators) {
            finalize_score(submission);
        };
        
        event::emit_event(&mut platform.validation_events, ValidationEvent {
            exam_id,
            validator: validator_addr,
            student,
            score,
        });
    }

    // Helper functions
    fun get_exam(platform: &ExamPlatform, exam_id: u64): &Exam {
        let i = 0;
        while (i < vector::length(&platform.exams)) {
            let exam = vector::borrow(&platform.exams, i);
            if (exam.exam_id == exam_id) {
                return exam
            };
            i = i + 1;
        };
        abort EEXAM_NOT_FOUND
    }

    fun get_exam_mut(platform: &mut ExamPlatform, exam_id: u64): &mut Exam {
        let i = 0;
        while (i < vector::length(&platform.exams)) {
            let exam = vector::borrow_mut(&mut platform.exams, i);
            if (exam.exam_id == exam_id) {
                return exam
            };
            i = i + 1;
        };
        abort EEXAM_NOT_FOUND
    }

    fun get_submission_mut(platform: &mut ExamPlatform, exam_id: u64, student: address): &mut Submission {
        let i = 0;
        while (i < vector::length(&mut platform.submissions)) {
            let submission = vector::borrow_mut(&mut platform.submissions, i);
            if (submission.exam_id == exam_id && submission.student == student) {
                return submission
            };
            i = i + 1;
        };
        abort EEXAM_NOT_FOUND
    }

    fun is_registered(platform: &ExamPlatform, exam_id: u64, student: address): bool {
        let i = 0;
        while (i < vector::length(&platform.registrations)) {
            let registration = vector::borrow(&platform.registrations, i);
            if (registration.exam_id == exam_id && registration.student == student) {
                return true
            };
            i = i + 1;
        };
        false
    }

    fun has_submitted(platform: &ExamPlatform, exam_id: u64, student: address): bool {
        let i = 0;
        while (i < vector::length(&platform.submissions)) {
            let submission = vector::borrow(&platform.submissions, i);
            if (submission.exam_id == exam_id && submission.student == student) {
                return true
            };
            i = i + 1;
        };
        false
    }

    fun finalize_score(submission: &mut Submission) {
        let total_score = 0u64;
        let count = vector::length(&submission.validations);
        let i = 0;
        
        while (i < count) {
            let validation = vector::borrow(&submission.validations, i);
            total_score = total_score + validation.score;
            i = i + 1;
        };
        
        submission.final_score = option::some(total_score / count);
    }

    // View functions
    public fun get_exam_details(platform: &ExamPlatform, exam_id: u64): (String, u64, u64, u64, bool) {
        let exam = get_exam(platform, exam_id);
        (
            *&exam.title,
            exam.start_time,
            exam.duration,
            exam.current_participants,
            exam.is_active
        )
    }

    public fun get_student_score(platform: &ExamPlatform, exam_id: u64, student: address): Option<u64> {
        let i = 0;
        while (i < vector::length(&platform.submissions)) {
            let submission = vector::borrow(&platform.submissions, i);
            if (submission.exam_id == exam_id && submission.student == student) {
                return *&submission.final_score
            };
            i = i + 1;
        };
        option::none()
    }
}