-- [Vận dụng cơ bản 2] - Kiểm soát trạng thái lịch khám
-- Database: RikkeiClinicDB

USE RikkeiClinicDB;

-- =========================
-- 🔹 Phần A: Phân tích
-- =========================
-- Câu lệnh UPDATE thử chuyển lịch khám có mã appointment_id = 104
-- từ trạng thái 'Pending' sang 'Completed' để quan sát lỗi do Trigger gây ra
UPDATE Appointments
SET status = 'Completed'
WHERE appointment_id = 104;

-- Giải thích:
-- Để kiểm tra xem một lịch khám trong quá khứ đã hoàn thành hay chưa,
-- ta phải dùng đối tượng OLD vì OLD.status phản ánh trạng thái trước khi cập nhật.
-- Trigger cũ kiểm tra trên NEW.status nên chặn cả các cập nhật hợp lệ.

-- =========================
-- 🔹 Phần B: Sửa chữa mã nguồn
-- =========================
-- Xóa trigger cũ
DROP TRIGGER IF EXISTS PreventStatusRevert;

-- Tạo trigger mới đúng logic
DELIMITER //
CREATE TRIGGER PreventStatusRevert
BEFORE UPDATE ON Appointments
FOR EACH ROW
BEGIN
    -- Nếu lịch khám đã hoàn thành thì không cho phép thay đổi trạng thái
    IF OLD.status = 'Completed' THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Không thể thay đổi trạng thái của lịch khám đã hoàn thành!';
    END IF;
END //
DELIMITER ;

-- =========================
-- 🔹 Kiểm thử
-- =========================
-- Thử UPDATE lại lịch khám đã có trạng thái 'Completed'
-- Hệ thống sẽ báo lỗi: "Không thể thay đổi trạng thái của lịch khám đã hoàn thành!"
