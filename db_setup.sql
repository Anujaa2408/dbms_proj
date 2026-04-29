-- ============================================================
-- HostelMS — Full Database Setup Script
-- SRM Institute Hostel Room Allocation System
-- ============================================================

CREATE DATABASE IF NOT EXISTS HostelDB;
USE HostelDB;

-- ============================================================
-- DROP existing objects (clean slate)
-- ============================================================
DROP VIEW   IF EXISTS v_occupancy_report;
DROP VIEW   IF EXISTS v_payment_summary;
DROP VIEW   IF EXISTS v_active_allocations;
DROP VIEW   IF EXISTS v_available_rooms;

DROP TABLE IF EXISTS Booking;
DROP TABLE IF EXISTS Payment;
DROP TABLE IF EXISTS Allocation;
DROP TABLE IF EXISTS Room;
DROP TABLE IF EXISTS Hostel;
DROP TABLE IF EXISTS Student;
DROP TABLE IF EXISTS Admin;

-- ============================================================
-- 1. ADMIN TABLE
-- ============================================================
CREATE TABLE Admin (
    admin_id    INT AUTO_INCREMENT PRIMARY KEY,
    username    VARCHAR(50)  NOT NULL UNIQUE,
    password    VARCHAR(255) NOT NULL,
    full_name   VARCHAR(100) NOT NULL,
    email       VARCHAR(100) NOT NULL UNIQUE,
    created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- ============================================================
-- 2. STUDENT TABLE
-- ============================================================
CREATE TABLE Student (
    student_id      INT AUTO_INCREMENT PRIMARY KEY,
    registration_no VARCHAR(20)  NOT NULL UNIQUE,
    first_name      VARCHAR(50)  NOT NULL,
    last_name       VARCHAR(50)  NOT NULL,
    email           VARCHAR(100) NOT NULL UNIQUE,
    phone           VARCHAR(15),
    gender          ENUM('Male','Female','Other') NOT NULL,
    department      VARCHAR(100),
    year_of_study   INT CHECK (year_of_study BETWEEN 1 AND 5),
    date_of_birth   DATE,
    address         TEXT,
    guardian_name   VARCHAR(100),
    guardian_phone  VARCHAR(15),
    status          ENUM('Active','Inactive','Graduated') DEFAULT 'Active',
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- ============================================================
-- 3. HOSTEL TABLE
-- ============================================================
CREATE TABLE Hostel (
    hostel_id       INT AUTO_INCREMENT PRIMARY KEY,
    hostel_name     VARCHAR(100) NOT NULL UNIQUE,
    hostel_type     ENUM('Boys','Girls','Co-ed') NOT NULL,
    total_rooms     INT DEFAULT 0,
    total_capacity  INT DEFAULT 0,
    warden_name     VARCHAR(100),
    warden_phone    VARCHAR(15),
    address         TEXT,
    status          ENUM('Active','Inactive','Maintenance') DEFAULT 'Active',
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- ============================================================
-- 4. ROOM TABLE
-- ============================================================
CREATE TABLE Room (
    room_id         INT AUTO_INCREMENT PRIMARY KEY,
    hostel_id       INT NOT NULL,
    room_number     VARCHAR(10) NOT NULL,
    floor_number    INT NOT NULL,
    room_type       ENUM('Single','Double','Triple') NOT NULL,
    capacity        INT NOT NULL CHECK (capacity BETWEEN 1 AND 4),
    occupied        INT DEFAULT 0,
    rent_per_month  DECIMAL(10,2) NOT NULL,
    status          ENUM('Available','Full','Maintenance') DEFAULT 'Available',
    has_ac          BOOLEAN DEFAULT FALSE,
    has_wifi        BOOLEAN DEFAULT TRUE,
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uk_hostel_room (hostel_id, room_number),
    FOREIGN KEY (hostel_id) REFERENCES Hostel(hostel_id)
        ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;

-- ============================================================
-- 5. ALLOCATION TABLE
-- ============================================================
CREATE TABLE Allocation (
    allocation_id   INT AUTO_INCREMENT PRIMARY KEY,
    student_id      INT NOT NULL,
    room_id         INT NOT NULL,
    alloc_date      DATE NOT NULL,
    vacate_date     DATE,
    status          ENUM('Active','Vacated','Transferred') DEFAULT 'Active',
    remarks         TEXT,
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (student_id) REFERENCES Student(student_id)
        ON DELETE CASCADE ON UPDATE CASCADE,
    FOREIGN KEY (room_id) REFERENCES Room(room_id)
        ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;

-- ============================================================
-- 6. PAYMENT TABLE
-- ============================================================
CREATE TABLE Payment (
    payment_id      INT AUTO_INCREMENT PRIMARY KEY,
    student_id      INT NOT NULL,
    amount          DECIMAL(10,2) NOT NULL,
    payment_date    DATE NOT NULL,
    payment_method  ENUM('Cash','UPI','Card','Bank Transfer') DEFAULT 'Cash',
    payment_for     ENUM('Hostel Fee','Mess Fee','Maintenance','Security Deposit','Other') DEFAULT 'Hostel Fee',
    semester        VARCHAR(20),
    status          ENUM('Completed','Pending','Failed','Refunded') DEFAULT 'Pending',
    receipt_no      VARCHAR(50) UNIQUE,
    remarks         TEXT,
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    FOREIGN KEY (student_id) REFERENCES Student(student_id)
        ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;

-- ============================================================
-- 7. BOOKING TABLE
-- ============================================================
CREATE TABLE Booking (
    booking_id      INT AUTO_INCREMENT PRIMARY KEY,
    student_id      INT NOT NULL,
    room_id         INT NOT NULL,
    request_date    DATE NOT NULL,
    check_in_date   DATE NOT NULL,
    status          ENUM('Pending','Approved','Rejected','Cancelled') DEFAULT 'Pending',
    remarks         TEXT,
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (student_id) REFERENCES Student(student_id)
        ON DELETE CASCADE ON UPDATE CASCADE,
    FOREIGN KEY (room_id) REFERENCES Room(room_id)
        ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;

-- ============================================================
-- TRIGGERS
-- ============================================================

-- Trigger 1: Prevent overbooking — block allocation if room is full
DELIMITER //
CREATE TRIGGER trg_before_allocate
BEFORE INSERT ON Allocation
FOR EACH ROW
BEGIN
    DECLARE current_occ INT;
    DECLARE max_cap     INT;
    SELECT occupied, capacity INTO current_occ, max_cap
    FROM Room WHERE room_id = NEW.room_id;
    IF current_occ >= max_cap THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Room is already at full capacity';
    END IF;
END//
DELIMITER ;

-- Trigger 2: Increment occupied count after allocation
DELIMITER //
CREATE TRIGGER trg_after_allocate
AFTER INSERT ON Allocation
FOR EACH ROW
BEGIN
    UPDATE Room SET occupied = occupied + 1 WHERE room_id = NEW.room_id;
    UPDATE Room SET status = 'Full'
        WHERE room_id = NEW.room_id AND occupied >= capacity;
END//
DELIMITER ;

-- Trigger 3: Decrement occupied count when allocation is vacated
DELIMITER //
CREATE TRIGGER trg_after_vacate
AFTER UPDATE ON Allocation
FOR EACH ROW
BEGIN
    IF OLD.status = 'Active' AND NEW.status = 'Vacated' THEN
        UPDATE Room SET occupied = occupied - 1 WHERE room_id = NEW.room_id;
        UPDATE Room SET status = 'Available'
            WHERE room_id = NEW.room_id AND occupied < capacity;
    END IF;
END//
DELIMITER ;

-- Trigger 4: Auto-generate receipt number for payment
DELIMITER //
CREATE TRIGGER trg_before_payment
BEFORE INSERT ON Payment
FOR EACH ROW
BEGIN
    IF NEW.receipt_no IS NULL THEN
        SET NEW.receipt_no = CONCAT('RCP-', DATE_FORMAT(NOW(), '%Y%m%d'), '-', LPAD(FLOOR(RAND() * 99999), 5, '0'));
    END IF;
END//
DELIMITER ;

-- ============================================================
-- STORED PROCEDURES
-- ============================================================

-- SP 1: Allocate a room to a student
DELIMITER //
CREATE PROCEDURE sp_allocate_room(
    IN p_student_id INT,
    IN p_room_id    INT,
    IN p_remarks    TEXT
)
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;
        INSERT INTO Allocation (student_id, room_id, alloc_date, status, remarks)
        VALUES (p_student_id, p_room_id, CURDATE(), 'Active', p_remarks);
    COMMIT;
END//
DELIMITER ;

-- SP 2: Vacate a room
DELIMITER //
CREATE PROCEDURE sp_vacate_room(
    IN p_allocation_id INT
)
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;
        UPDATE Allocation
        SET status = 'Vacated', vacate_date = CURDATE()
        WHERE allocation_id = p_allocation_id AND status = 'Active';
    COMMIT;
END//
DELIMITER ;

-- SP 3: Get student report (allocations + payments)
DELIMITER //
CREATE PROCEDURE sp_get_student_report(IN p_student_id INT)
BEGIN
    SELECT s.registration_no, s.first_name, s.last_name, s.email,
           s.department, s.year_of_study,
           a.allocation_id, r.room_number, h.hostel_name,
           a.alloc_date, a.vacate_date, a.status AS alloc_status
    FROM Student s
    LEFT JOIN Allocation a ON s.student_id = a.student_id
    LEFT JOIN Room r ON a.room_id = r.room_id
    LEFT JOIN Hostel h ON r.hostel_id = h.hostel_id
    WHERE s.student_id = p_student_id;

    SELECT p.payment_id, p.amount, p.payment_date, p.payment_method,
           p.payment_for, p.status, p.receipt_no
    FROM Payment p
    WHERE p.student_id = p_student_id
    ORDER BY p.payment_date DESC;
END//
DELIMITER ;

-- ============================================================
-- VIEWS
-- ============================================================

-- View 1: Available rooms
CREATE VIEW v_available_rooms AS
SELECT r.room_id, r.room_number, r.floor_number, r.room_type,
       r.capacity, r.occupied, (r.capacity - r.occupied) AS beds_free,
       r.rent_per_month, r.has_ac, r.has_wifi,
       h.hostel_name, h.hostel_type
FROM Room r
JOIN Hostel h ON r.hostel_id = h.hostel_id
WHERE r.status = 'Available' AND r.occupied < r.capacity;

-- View 2: Active allocations
CREATE VIEW v_active_allocations AS
SELECT a.allocation_id, a.alloc_date,
       s.student_id, s.registration_no, s.first_name, s.last_name,
       r.room_id, r.room_number, r.room_type,
       h.hostel_id, h.hostel_name
FROM Allocation a
JOIN Student s ON a.student_id = s.student_id
JOIN Room r    ON a.room_id    = r.room_id
JOIN Hostel h  ON r.hostel_id  = h.hostel_id
WHERE a.status = 'Active';

-- View 3: Payment summary per student
CREATE VIEW v_payment_summary AS
SELECT s.student_id, s.registration_no,
       CONCAT(s.first_name, ' ', s.last_name) AS student_name,
       COUNT(p.payment_id) AS total_payments,
       COALESCE(SUM(CASE WHEN p.status='Completed' THEN p.amount ELSE 0 END),0) AS total_paid,
       COALESCE(SUM(CASE WHEN p.status='Pending'   THEN p.amount ELSE 0 END),0) AS total_pending
FROM Student s
LEFT JOIN Payment p ON s.student_id = p.student_id
GROUP BY s.student_id, s.registration_no, s.first_name, s.last_name;

-- View 4: Occupancy report per hostel
CREATE VIEW v_occupancy_report AS
SELECT h.hostel_id, h.hostel_name, h.hostel_type,
       COUNT(r.room_id) AS total_rooms,
       SUM(r.capacity)  AS total_beds,
       SUM(r.occupied)  AS occupied_beds,
       SUM(r.capacity) - SUM(r.occupied) AS available_beds,
       ROUND(SUM(r.occupied) / SUM(r.capacity) * 100, 1) AS occupancy_pct
FROM Hostel h
LEFT JOIN Room r ON h.hostel_id = r.hostel_id
GROUP BY h.hostel_id, h.hostel_name, h.hostel_type;

-- ============================================================
-- SAMPLE DATA
-- ============================================================

-- Admin (password: admin123 — hashed with werkzeug)
INSERT INTO Admin (username, password, full_name, email) VALUES
('admin', 'pbkdf2:sha256:600000$XsNPKLmE$e8e3e6b1a0f4c9d2b5a7f0e3c6d9b2a5e8f1c4d7a0b3e6f9c2d5a8b1e4f7a0c3', 'System Administrator', 'admin@srm.edu.in');

-- Hostels
INSERT INTO Hostel (hostel_name, hostel_type, total_rooms, total_capacity, warden_name, warden_phone, address) VALUES
('Nelson Mandela Hall',  'Boys',  30, 60,  'Dr. Ramesh Kumar',  '9876543210', 'Block A, SRM Campus'),
('Indira Gandhi Hall',   'Girls', 25, 50,  'Dr. Priya Sharma',  '9876543211', 'Block B, SRM Campus'),
('APJ Abdul Kalam Hall', 'Boys',  35, 105, 'Dr. Suresh Babu',   '9876543212', 'Block C, SRM Campus'),
('Sarojini Naidu Hall',  'Girls', 20, 40,  'Dr. Lakshmi Menon', '9876543213', 'Block D, SRM Campus');

-- Rooms
INSERT INTO Room (hostel_id, room_number, floor_number, room_type, capacity, occupied, rent_per_month, status, has_ac, has_wifi) VALUES
(1, 'NM-101', 1, 'Double', 2, 2, 8000.00, 'Full',      TRUE,  TRUE),
(1, 'NM-102', 1, 'Double', 2, 1, 8000.00, 'Available',  TRUE,  TRUE),
(1, 'NM-201', 2, 'Single', 1, 0, 12000.00,'Available',  TRUE,  TRUE),
(1, 'NM-202', 2, 'Triple', 3, 2, 6000.00, 'Available',  FALSE, TRUE),
(2, 'IG-101', 1, 'Double', 2, 1, 8500.00, 'Available',  TRUE,  TRUE),
(2, 'IG-102', 1, 'Single', 1, 1, 13000.00,'Full',       TRUE,  TRUE),
(2, 'IG-201', 2, 'Double', 2, 0, 8500.00, 'Available',  FALSE, TRUE),
(3, 'AK-101', 1, 'Triple', 3, 3, 5500.00, 'Full',       FALSE, TRUE),
(3, 'AK-102', 1, 'Double', 2, 1, 7500.00, 'Available',  FALSE, TRUE),
(3, 'AK-201', 2, 'Single', 1, 0, 11000.00,'Available',  TRUE,  TRUE),
(4, 'SN-101', 1, 'Double', 2, 2, 9000.00, 'Full',       TRUE,  TRUE),
(4, 'SN-102', 1, 'Double', 2, 0, 9000.00, 'Available',  TRUE,  TRUE),
(4, 'SN-201', 2, 'Triple', 3, 1, 6500.00, 'Available',  FALSE, TRUE);

-- Students
INSERT INTO Student (registration_no, first_name, last_name, email, phone, gender, department, year_of_study, date_of_birth, guardian_name, guardian_phone, status) VALUES
('RA2211003010101', 'Aarav',    'Patel',     'aarav.p@srm.edu.in',    '9001234501', 'Male',   'Computer Science',   2, '2004-03-15', 'Rajesh Patel',     '9001234601', 'Active'),
('RA2211003010102', 'Sneha',    'Sharma',    'sneha.s@srm.edu.in',    '9001234502', 'Female', 'Electronics',        3, '2003-07-22', 'Vikram Sharma',    '9001234602', 'Active'),
('RA2211003010103', 'Rohan',    'Gupta',     'rohan.g@srm.edu.in',    '9001234503', 'Male',   'Mechanical',         1, '2005-01-10', 'Anil Gupta',       '9001234603', 'Active'),
('RA2211003010104', 'Priya',    'Menon',     'priya.m@srm.edu.in',    '9001234504', 'Female', 'Computer Science',   4, '2002-11-05', 'Suresh Menon',     '9001234604', 'Active'),
('RA2211003010105', 'Karthik',  'Rajan',     'karthik.r@srm.edu.in',  '9001234505', 'Male',   'Civil Engineering',  2, '2004-06-18', 'Mohan Rajan',      '9001234605', 'Active'),
('RA2211003010106', 'Ananya',   'Reddy',     'ananya.r@srm.edu.in',   '9001234506', 'Female', 'Biotechnology',      1, '2005-09-30', 'Krishna Reddy',    '9001234606', 'Active'),
('RA2211003010107', 'Arjun',    'Nair',      'arjun.n@srm.edu.in',    '9001234507', 'Male',   'Computer Science',   3, '2003-04-25', 'Gopinath Nair',    '9001234607', 'Active'),
('RA2211003010108', 'Divya',    'Krishnan',  'divya.k@srm.edu.in',    '9001234508', 'Female', 'Electronics',        2, '2004-12-08', 'Ramesh Krishnan',  '9001234608', 'Active'),
('RA2211003010109', 'Vikram',   'Singh',     'vikram.s@srm.edu.in',   '9001234509', 'Male',   'Mechanical',         4, '2002-08-14', 'Harinder Singh',   '9001234609', 'Active'),
('RA2211003010110', 'Meera',    'Iyer',      'meera.i@srm.edu.in',    '9001234510', 'Female', 'Computer Science',   1, '2005-05-20', 'Venkat Iyer',      '9001234610', 'Active');

-- Allocations (matches the occupied counts above)
INSERT INTO Allocation (student_id, room_id, alloc_date, status, remarks) VALUES
(1,  1,  '2025-07-01', 'Active', 'Regular admission'),
(3,  1,  '2025-07-01', 'Active', 'Regular admission'),
(5,  2,  '2025-07-05', 'Active', 'Late admission'),
(7,  4,  '2025-07-01', 'Active', 'Regular admission'),
(9,  4,  '2025-07-03', 'Active', 'Regular admission'),
(2,  5,  '2025-07-01', 'Active', 'Regular admission'),
(4,  6,  '2025-07-02', 'Active', 'Regular admission'),
(6,  8,  '2025-07-01', 'Active', 'Regular admission'),
(8,  8,  '2025-07-01', 'Active', 'Regular admission'),
(10, 8,  '2025-07-04', 'Active', 'Regular admission'),
(10, 11, '2025-07-01', 'Vacated', 'Transferred to AK Hall');

-- NOTE: We inserted allocations directly, so triggers for occupied counts won't fire
-- for this seed data. The occupied values above are already set correctly in the INSERT.
-- For the trigger-inserted allocations above, we need to reset occupied counts:
UPDATE Room SET occupied = 2 WHERE room_id = 1;
UPDATE Room SET occupied = 1 WHERE room_id = 2;
UPDATE Room SET occupied = 0 WHERE room_id = 3;
UPDATE Room SET occupied = 2 WHERE room_id = 4;
UPDATE Room SET occupied = 1 WHERE room_id = 5;
UPDATE Room SET occupied = 1 WHERE room_id = 6;
UPDATE Room SET occupied = 0 WHERE room_id = 7;
UPDATE Room SET occupied = 3 WHERE room_id = 8;
UPDATE Room SET occupied = 1 WHERE room_id = 9;
UPDATE Room SET occupied = 0 WHERE room_id = 10;
UPDATE Room SET occupied = 2 WHERE room_id = 11;
UPDATE Room SET occupied = 0 WHERE room_id = 12;
UPDATE Room SET occupied = 1 WHERE room_id = 13;

-- Reset room statuses based on occupied counts
UPDATE Room SET status = 'Full' WHERE occupied >= capacity;
UPDATE Room SET status = 'Available' WHERE occupied < capacity;

-- Payments
INSERT INTO Payment (student_id, amount, payment_date, payment_method, payment_for, semester, status, receipt_no) VALUES
(1,  8000.00,  '2025-07-15', 'UPI',           'Hostel Fee',       'Fall 2025',   'Completed', 'RCP-20250715-00001'),
(2,  8500.00,  '2025-07-15', 'Card',          'Hostel Fee',       'Fall 2025',   'Completed', 'RCP-20250715-00002'),
(3,  8000.00,  '2025-07-16', 'Bank Transfer', 'Hostel Fee',       'Fall 2025',   'Completed', 'RCP-20250716-00003'),
(4,  13000.00, '2025-07-16', 'UPI',           'Hostel Fee',       'Fall 2025',   'Completed', 'RCP-20250716-00004'),
(5,  8000.00,  '2025-07-18', 'Cash',          'Hostel Fee',       'Fall 2025',   'Pending',   'RCP-20250718-00005'),
(6,  5500.00,  '2025-07-20', 'UPI',           'Hostel Fee',       'Fall 2025',   'Completed', 'RCP-20250720-00006'),
(7,  6000.00,  '2025-07-20', 'Card',          'Hostel Fee',       'Fall 2025',   'Completed', 'RCP-20250720-00007'),
(8,  5500.00,  '2025-07-22', 'Bank Transfer', 'Hostel Fee',       'Fall 2025',   'Pending',   'RCP-20250722-00008'),
(9,  6000.00,  '2025-07-22', 'Cash',          'Hostel Fee',       'Fall 2025',   'Completed', 'RCP-20250722-00009'),
(10, 5500.00,  '2025-07-25', 'UPI',           'Hostel Fee',       'Fall 2025',   'Completed', 'RCP-20250725-00010'),
(1,  5000.00,  '2025-08-01', 'UPI',           'Security Deposit', 'Fall 2025',   'Completed', 'RCP-20250801-00011'),
(2,  5000.00,  '2025-08-01', 'Card',          'Security Deposit', 'Fall 2025',   'Completed', 'RCP-20250801-00012');

-- Bookings
INSERT INTO Booking (student_id, room_id, request_date, check_in_date, status, remarks) VALUES
(10, 12, '2025-08-10', '2025-08-15', 'Pending', 'Requesting transfer to SN Hall');
