USE RikkeiClinicDB;

CREATE TABLE Wallet_Transactions (
    transaction_id INT AUTO_INCREMENT PRIMARY KEY,
    patient_id INT NOT NULL,
    change_amount DECIMAL(18,2) NOT NULL,
    balance_after DECIMAL(18,2) NOT NULL,
    transaction_type VARCHAR(50) NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (patient_id) REFERENCES Patients(patient_id)
);

CREATE TABLE LowStockAlerts (
    alert_id INT AUTO_INCREMENT PRIMARY KEY,
    item_type VARCHAR(20) NOT NULL,
    item_id INT NOT NULL,
    item_name VARCHAR(150) NOT NULL,
    current_stock INT NOT NULL,
    threshold INT NOT NULL,
    alerted_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

DELIMITER $$

CREATE PROCEDURE sp_wallet_top_up(
    IN p_patient_id INT,
    IN p_amount DECIMAL(18,2)
)
BEGIN
    DECLARE v_balance DECIMAL(18,2);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'ERROR' AS status, 'Transaction rolled back' AS message;
    END;

    START TRANSACTION;

    SELECT balance INTO v_balance FROM Wallets WHERE patient_id = p_patient_id FOR UPDATE;
    IF v_balance IS NULL THEN
        INSERT INTO Wallets (patient_id, balance, status) VALUES (p_patient_id, p_amount, 'Active');
        SET v_balance = p_amount;
    ELSE
        UPDATE Wallets SET balance = balance + p_amount WHERE patient_id = p_patient_id;
        SET v_balance = v_balance + p_amount;
    END IF;

    INSERT INTO Wallet_Transactions (patient_id, change_amount, balance_after, transaction_type)
    VALUES (p_patient_id, p_amount, v_balance, 'TopUp');

    COMMIT;
    SELECT 'OK' AS status, CONCAT('New balance: ', v_balance) AS message;
END$$

DELIMITER ;

DELIMITER $$

CREATE PROCEDURE sp_pay_invoice_with_wallet(
    IN p_patient_id INT,
    IN p_pay_amount DECIMAL(18,2)
)
BEGIN
    DECLARE v_balance DECIMAL(18,2);
    DECLARE v_total_due DECIMAL(18,2);
    DECLARE v_new_balance DECIMAL(18,2);
    DECLARE v_new_total_due DECIMAL(18,2);
    DECLARE v_wallet_status VARCHAR(20);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'ERROR' AS status, 'Transaction rolled back' AS message;
    END;

    START TRANSACTION;

    SELECT balance, status INTO v_balance, v_wallet_status FROM Wallets WHERE patient_id = p_patient_id FOR UPDATE;
    IF v_balance IS NULL THEN
        ROLLBACK;
        SELECT 'ERROR' AS status, 'Wallet not found' AS message;
        LEAVE proc_end_pay;
    END IF;

    IF v_wallet_status <> 'Active' THEN
        ROLLBACK;
        SELECT 'ERROR' AS status, 'Wallet inactive' AS message;
        LEAVE proc_end_pay;
    END IF;

    IF v_balance < p_pay_amount THEN
        ROLLBACK;
        SELECT 'ERROR' AS status, 'Insufficient wallet balance' AS message;
        LEAVE proc_end_pay;
    END IF;

    SELECT total_due INTO v_total_due FROM Patient_Invoices WHERE patient_id = p_patient_id FOR UPDATE;
    IF v_total_due IS NULL THEN
        INSERT INTO Patient_Invoices (patient_id, total_due) VALUES (p_patient_id, 0);
        SET v_total_due = 0;
    END IF;

    SET v_new_balance = v_balance - p_pay_amount;
    SET v_new_total_due = v_total_due - p_pay_amount;
    IF v_new_total_due < 0 THEN
        SET v_new_total_due = 0;
    END IF;

    UPDATE Wallets SET balance = v_new_balance WHERE patient_id = p_patient_id;
    INSERT INTO Wallet_Transactions (patient_id, change_amount, balance_after, transaction_type)
    VALUES (p_patient_id, -p_pay_amount, v_new_balance, 'InvoicePayment');

    UPDATE Patient_Invoices SET total_due = v_new_total_due, last_updated = CURRENT_TIMESTAMP WHERE patient_id = p_patient_id;

    COMMIT;
    SELECT 'OK' AS status, CONCAT('Paid ', p_pay_amount, '. New balance: ', v_new_balance, '. New total_due: ', v_new_total_due) AS message;

    proc_end_pay: BEGIN END;
END$$

DELIMITER ;

DELIMITER $$

CREATE PROCEDURE sp_discharge_patient(
    IN p_patient_id INT
)
BEGIN
    DECLARE v_total_due DECIMAL(18,2);
    DECLARE v_exists INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'ERROR' AS status, 'Transaction rolled back' AS message;
    END;

    START TRANSACTION;

    SELECT COUNT(*) INTO v_exists FROM Beds WHERE patient_id = p_patient_id FOR UPDATE;
    IF v_exists = 0 THEN
        ROLLBACK;
        SELECT 'ERROR' AS status, 'Patient not assigned to any bed' AS message;
        LEAVE proc_end_discharge;
    END IF;

    SELECT total_due INTO v_total_due FROM Patient_Invoices WHERE patient_id = p_patient_id FOR UPDATE;
    IF v_total_due IS NULL THEN
        SET v_total_due = 0;
    END IF;

    IF v_total_due > 0 THEN
        ROLLBACK;
        SELECT 'ERROR' AS status, 'Outstanding invoice exists' AS message;
        LEAVE proc_end_discharge;
    END IF;

    UPDATE Beds SET patient_id = NULL WHERE patient_id = p_patient_id;

    COMMIT;
    SELECT 'OK' AS status, 'Patient discharged and bed released' AS message;

    proc_end_discharge: BEGIN END;
END$$

DELIMITER ;

DELIMITER $$

CREATE PROCEDURE sp_restock_medicine(
    IN p_medicine_id INT,
    IN p_quantity INT,
    IN p_threshold INT
)
BEGIN
    DECLARE v_stock INT;
    DECLARE v_name VARCHAR(150);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'ERROR' AS status, 'Transaction rolled back' AS message;
    END;

    START TRANSACTION;

    SELECT stock, name INTO v_stock, v_name FROM Medicines WHERE medicine_id = p_medicine_id FOR UPDATE;
    IF v_stock IS NULL THEN
        ROLLBACK;
        SELECT 'ERROR' AS status, 'Medicine not found' AS message;
        LEAVE proc_end_restock;
    END IF;

    UPDATE Medicines SET stock = stock + p_quantity WHERE medicine_id = p_medicine_id;

    SET v_stock = v_stock + p_quantity;
    IF v_stock <= p_threshold THEN
        INSERT INTO LowStockAlerts (item_type, item_id, item_name, current_stock, threshold)
        VALUES ('Medicine', p_medicine_id, v_name, v_stock, p_threshold);
    END IF;

    COMMIT;
    SELECT 'OK' AS status, CONCAT('Medicine restocked. Current stock: ', v_stock) AS message;

    proc_end_restock: BEGIN END;
END$$

DELIMITER ;

DELIMITER $$

CREATE PROCEDURE sp_transfer_bed(
    IN p_from_bed_id INT,
    IN p_to_bed_id INT
)
BEGIN
    DECLARE v_patient_id INT;
    DECLARE v_to_patient INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'ERROR' AS status, 'Transaction rolled back' AS message;
    END;

    START TRANSACTION;

    SELECT patient_id INTO v_patient_id FROM Beds WHERE bed_id = p_from_bed_id FOR UPDATE;
    IF v_patient_id IS NULL THEN
        ROLLBACK;
        SELECT 'ERROR' AS status, 'Source bed is empty' AS message;
        LEAVE proc_end_transfer;
    END IF;

    SELECT patient_id INTO v_to_patient FROM Beds WHERE bed_id = p_to_bed_id FOR UPDATE;
    IF v_to_patient IS NOT NULL THEN
        ROLLBACK;
        SELECT 'ERROR' AS status, 'Destination bed is occupied' AS message;
        LEAVE proc_end_transfer;
    END IF;

    UPDATE Beds SET patient_id = NULL WHERE bed_id = p_from_bed_id;
    UPDATE Beds SET patient_id = v_patient_id WHERE bed_id = p_to_bed_id;

    COMMIT;
    SELECT 'OK' AS status, CONCAT('Patient ', v_patient_id, ' transferred from bed ', p_from_bed_id, ' to bed ', p_to_bed_id) AS message;

    proc_end_transfer: BEGIN END;
END$$

DELIMITER ;

SELECT b.bed_id, d.dept_name, p.patient_id, p.full_name
FROM Beds b
JOIN Departments d ON b.dept_id = d.dept_id
LEFT JOIN Patients p ON b.patient_id = p.patient_id;

SELECT medicine_id, name, stock FROM Medicines WHERE stock < 10;

CALL sp_wallet_top_up(2, 200000);
SELECT * FROM Wallets WHERE patient_id = 2;
SELECT * FROM Wallet_Transactions WHERE patient_id = 2 ORDER BY created_at DESC LIMIT 5;

CALL sp_pay_invoice_with_wallet(1, 1500000);
SELECT * FROM Patient_Invoices WHERE patient_id = 1;
SELECT * FROM Wallets WHERE patient_id = 1;
SELECT * FROM Beds WHERE patient_id = 1;

CALL sp_discharge_patient(1);
SELECT * FROM Beds WHERE patient_id IS NULL;

CALL sp_restock_medicine(2, 20, 10);
SELECT * FROM Medicines WHERE medicine_id = 2;
SELECT * FROM LowStockAlerts ORDER BY alerted_at DESC LIMIT 5;

CALL sp_transfer_bed(101, 201);
SELECT * FROM Beds WHERE bed_id IN (101,201);
