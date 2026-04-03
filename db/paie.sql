CREATE TABLE IF NOT EXISTS payroll_employees (
	id INT AUTO_INCREMENT PRIMARY KEY,
	employee_code VARCHAR(32) NOT NULL UNIQUE,
	full_name VARCHAR(120) NOT NULL,
	department VARCHAR(80) NOT NULL,
	monthly_salary DECIMAL(10,2) NOT NULL,
	active TINYINT(1) NOT NULL DEFAULT 1,
	created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS payroll_runs (
	id INT AUTO_INCREMENT PRIMARY KEY,
	employee_id INT NOT NULL,
	period_label VARCHAR(20) NOT NULL,
	gross_amount DECIMAL(10,2) NOT NULL,
	net_amount DECIMAL(10,2) NOT NULL,
	status VARCHAR(20) NOT NULL DEFAULT 'draft',
	created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
	CONSTRAINT fk_payroll_runs_employee
		FOREIGN KEY (employee_id) REFERENCES payroll_employees(id)
		ON DELETE CASCADE
);

INSERT INTO payroll_employees (employee_code, full_name, department, monthly_salary, active)
VALUES
	('EMP-001', 'Alice Manao', 'Administration', 3200.00, 1),
	('EMP-002', 'Boris Nomena', 'Finance', 4100.00, 1),
	('EMP-003', 'Clara Rabe', 'Operations', 2950.00, 1)
ON DUPLICATE KEY UPDATE
	full_name = VALUES(full_name),
	department = VALUES(department),
	monthly_salary = VALUES(monthly_salary),
	active = VALUES(active);

INSERT INTO payroll_runs (employee_id, period_label, gross_amount, net_amount, status)
SELECT employee_id, period_label, gross_amount, net_amount, status
FROM (
	SELECT e.id AS employee_id, '2026-03' AS period_label, 3200.00 AS gross_amount, 2860.00 AS net_amount, 'validated' AS status
	FROM payroll_employees e
	WHERE e.employee_code = 'EMP-001'

	UNION ALL

	SELECT e.id AS employee_id, '2026-03' AS period_label, 4100.00 AS gross_amount, 3585.00 AS net_amount, 'validated' AS status
	FROM payroll_employees e
	WHERE e.employee_code = 'EMP-002'

	UNION ALL

	SELECT e.id AS employee_id, '2026-03' AS period_label, 2950.00 AS gross_amount, 2642.50 AS net_amount, 'draft' AS status
	FROM payroll_employees e
	WHERE e.employee_code = 'EMP-003'
) AS seed_rows
WHERE NOT EXISTS (
	SELECT 1
	FROM payroll_runs pr
	WHERE pr.employee_id = seed_rows.employee_id
	  AND pr.period_label = seed_rows.period_label
);
