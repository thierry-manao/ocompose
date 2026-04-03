CREATE TABLE IF NOT EXISTS sales_customers (
	id INT AUTO_INCREMENT PRIMARY KEY,
	customer_code VARCHAR(32) NOT NULL UNIQUE,
	company_name VARCHAR(120) NOT NULL,
	city VARCHAR(80) NOT NULL,
	status VARCHAR(20) NOT NULL DEFAULT 'active',
	created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS sales_products (
	id INT AUTO_INCREMENT PRIMARY KEY,
	sku VARCHAR(32) NOT NULL UNIQUE,
	product_name VARCHAR(120) NOT NULL,
	unit_price DECIMAL(10,2) NOT NULL,
	stock_qty INT NOT NULL DEFAULT 0,
	created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS sales_orders (
	id INT AUTO_INCREMENT PRIMARY KEY,
	order_number VARCHAR(40) NOT NULL UNIQUE,
	customer_id INT NOT NULL,
	product_id INT NOT NULL,
	quantity INT NOT NULL,
	total_amount DECIMAL(10,2) NOT NULL,
	status VARCHAR(20) NOT NULL DEFAULT 'draft',
	created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
	CONSTRAINT fk_sales_orders_customer
		FOREIGN KEY (customer_id) REFERENCES sales_customers(id)
		ON DELETE CASCADE,
	CONSTRAINT fk_sales_orders_product
		FOREIGN KEY (product_id) REFERENCES sales_products(id)
		ON DELETE CASCADE
);

INSERT INTO sales_customers (customer_code, company_name, city, status)
VALUES
	('CLI-001', 'Manao Services', 'Antananarivo', 'active'),
	('CLI-002', 'Ocean Trade', 'Toamasina', 'active'),
	('CLI-003', 'Plateau Retail', 'Fianarantsoa', 'prospect')
ON DUPLICATE KEY UPDATE
	company_name = VALUES(company_name),
	city = VALUES(city),
	status = VALUES(status);

INSERT INTO sales_products (sku, product_name, unit_price, stock_qty)
VALUES
	('ART-001', 'Business Suite License', 199.00, 25),
	('ART-002', 'Payroll Module', 149.00, 18),
	('ART-003', 'Support Pack', 79.00, 50)
ON DUPLICATE KEY UPDATE
	product_name = VALUES(product_name),
	unit_price = VALUES(unit_price),
	stock_qty = VALUES(stock_qty);

INSERT INTO sales_orders (order_number, customer_id, product_id, quantity, total_amount, status)
SELECT order_number, customer_id, product_id, quantity, total_amount, status
FROM (
	SELECT 'SO-2026-001' AS order_number, c.id AS customer_id, p.id AS product_id, 5 AS quantity, 995.00 AS total_amount, 'confirmed' AS status
	FROM sales_customers c
	JOIN sales_products p ON p.sku = 'ART-001'
	WHERE c.customer_code = 'CLI-001'

	UNION ALL

	SELECT 'SO-2026-002' AS order_number, c.id AS customer_id, p.id AS product_id, 3 AS quantity, 447.00 AS total_amount, 'draft' AS status
	FROM sales_customers c
	JOIN sales_products p ON p.sku = 'ART-002'
	WHERE c.customer_code = 'CLI-002'
) AS seed_rows
WHERE NOT EXISTS (
	SELECT 1
	FROM sales_orders o
	WHERE o.order_number = seed_rows.order_number
);
