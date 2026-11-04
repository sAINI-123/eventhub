-- =====================================================
--  EVENTHUB : EVENT MANAGEMENT & TICKETING PLATFORM
-- 
BEGIN
  FOR t IN (SELECT table_name FROM user_tables
            WHERE table_name IN ('PAYMENTS','BOOKINGS','EVENTS','VENUES','USERS')) LOOP
    EXECUTE IMMEDIATE 'DROP TABLE ' || t.table_name || ' CASCADE CONSTRAINTS';
  END LOOP;
  FOR s IN (SELECT sequence_name FROM user_sequences
            WHERE sequence_name IN ('USER_SEQ','VENUE_SEQ','EVENT_SEQ','BOOKING_SEQ','PAYMENT_SEQ')) LOOP
    EXECUTE IMMEDIATE 'DROP SEQUENCE ' || s.sequence_name;
  END LOOP;
END;
/

-- ---------- 1. SEQUENCES ----------
CREATE SEQUENCE user_seq    START WITH 1 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE venue_seq   START WITH 1 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE event_seq   START WITH 1 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE booking_seq START WITH 1001 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE payment_seq START WITH 1 INCREMENT BY 1 NOCACHE;

-- ---------- 2. TABLES ----------
CREATE TABLE users (
  user_id    NUMBER        PRIMARY KEY,
  name       VARCHAR2(100) NOT NULL,
  email      VARCHAR2(100) NOT NULL UNIQUE,
  phone      VARCHAR2(15),
  created_on DATE          DEFAULT SYSDATE
);

CREATE TABLE venues (
  venue_id NUMBER        PRIMARY KEY,
  name     VARCHAR2(120) NOT NULL,
  city     VARCHAR2(60)  NOT NULL,
  capacity NUMBER        CHECK (capacity > 0)
);

CREATE TABLE events (
  event_id         NUMBER        PRIMARY KEY,
  title            VARCHAR2(150) NOT NULL,
  category         VARCHAR2(40)  NOT NULL,
  description      VARCHAR2(400),
  venue_id         NUMBER        NOT NULL REFERENCES venues(venue_id),
  event_date       DATE          NOT NULL,
  ticket_price     NUMBER(8,2)   NOT NULL CHECK (ticket_price >= 0),
  total_seats      NUMBER        NOT NULL CHECK (total_seats > 0),
  available_seats  NUMBER        CHECK (available_seats >= 0),
  status           VARCHAR2(10)  DEFAULT 'UPCOMING'
                   CHECK (status IN ('UPCOMING','CANCELLED','COMPLETED')),
  CONSTRAINT chk_seats CHECK (available_seats <= total_seats)
);

CREATE TABLE bookings (
  booking_id    NUMBER       PRIMARY KEY,
  user_id       NUMBER       NOT NULL REFERENCES users(user_id),
  event_id      NUMBER       NOT NULL REFERENCES events(event_id),
  num_tickets   NUMBER       NOT NULL CHECK (num_tickets BETWEEN 1 AND 6),
  total_amount  NUMBER(10,2) NOT NULL,
  booking_date  DATE         DEFAULT SYSDATE,
  status        VARCHAR2(10) DEFAULT 'CONFIRMED'
                CHECK (status IN ('CONFIRMED','CANCELLED')),
  refund_amount NUMBER(10,2) DEFAULT 0
);

CREATE TABLE payments (
  payment_id NUMBER       PRIMARY KEY,
  booking_id NUMBER       NOT NULL REFERENCES bookings(booking_id),
  amount     NUMBER(10,2) NOT NULL,
  method     VARCHAR2(15) CHECK (method IN ('UPI','CARD','NETBANKING','CASH')),
  paid_on    DATE         DEFAULT SYSDATE
);

-- ---------- 3. TRIGGERS ----------
-- 3a. Auto ID triggers
CREATE OR REPLACE TRIGGER trg_user_id
BEFORE INSERT ON users FOR EACH ROW
BEGIN
  IF :NEW.user_id IS NULL THEN :NEW.user_id := user_seq.NEXTVAL; END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_venue_id
BEFORE INSERT ON venues FOR EACH ROW
BEGIN
  IF :NEW.venue_id IS NULL THEN :NEW.venue_id := venue_seq.NEXTVAL; END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_event_id
BEFORE INSERT ON events FOR EACH ROW
BEGIN
  IF :NEW.event_id IS NULL THEN :NEW.event_id := event_seq.NEXTVAL; END IF;
  IF :NEW.available_seats IS NULL THEN :NEW.available_seats := :NEW.total_seats; END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_booking_id
BEFORE INSERT ON bookings FOR EACH ROW
BEGIN
  IF :NEW.booking_id IS NULL THEN :NEW.booking_id := booking_seq.NEXTVAL; END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_payment_id
BEFORE INSERT ON payments FOR EACH ROW
BEGIN
  IF :NEW.payment_id IS NULL THEN :NEW.payment_id := payment_seq.NEXTVAL; END IF;
END;
/

-- 3b. Event cancel hone par sabhi bookings automatically cancel + full refund
CREATE OR REPLACE TRIGGER trg_event_cancelled
AFTER UPDATE OF status ON events
FOR EACH ROW
WHEN (NEW.status = 'CANCELLED' AND OLD.status <> 'CANCELLED')
BEGIN
  UPDATE bookings
  SET status = 'CANCELLED',
      refund_amount = total_amount
  WHERE event_id = :NEW.event_id
    AND status = 'CONFIRMED';
END;
/

-- ---------- 4. FUNCTION : total amount (4+ tickets par 10% group discount) ----------
CREATE OR REPLACE FUNCTION calc_total (
  p_event_id IN NUMBER,
  p_qty      IN NUMBER
) RETURN NUMBER IS
  v_price events.ticket_price%TYPE;
  v_total NUMBER;
BEGIN
  SELECT ticket_price INTO v_price FROM events WHERE event_id = p_event_id;
  v_total := v_price * p_qty;
  IF p_qty >= 4 THEN
    v_total := v_total * 0.90;
  END IF;
  RETURN ROUND(v_total, 2);
END calc_total;
/

-- ---------- 5. PROCEDURE : ticket book karna ----------
CREATE OR REPLACE PROCEDURE book_ticket (
  p_user_id    IN  NUMBER,
  p_event_id   IN  NUMBER,
  p_qty        IN  NUMBER,
  p_method     IN  VARCHAR2 DEFAULT 'UPI',
  p_booking_id OUT NUMBER
) IS
  v_user      users.name%TYPE;
  v_title     events.title%TYPE;
  v_status    events.status%TYPE;
  v_date      events.event_date%TYPE;
  v_avail     events.available_seats%TYPE;
  v_total     NUMBER;
  e_bad_qty   EXCEPTION;
  e_closed    EXCEPTION;
  e_no_seats  EXCEPTION;
BEGIN
  IF p_qty < 1 OR p_qty > 6 THEN
    RAISE e_bad_qty;
  END IF;

  SELECT name INTO v_user FROM users WHERE user_id = p_user_id;

  SELECT title, status, event_date, available_seats
  INTO   v_title, v_status, v_date, v_avail
  FROM   events WHERE event_id = p_event_id FOR UPDATE;

  IF v_status <> 'UPCOMING' OR v_date < SYSDATE THEN
    RAISE e_closed;
  END IF;

  IF v_avail < p_qty THEN
    RAISE e_no_seats;
  END IF;

  v_total := calc_total(p_event_id, p_qty);

  INSERT INTO bookings (user_id, event_id, num_tickets, total_amount)
  VALUES (p_user_id, p_event_id, p_qty, v_total)
  RETURNING booking_id INTO p_booking_id;

  INSERT INTO payments (booking_id, amount, method)
  VALUES (p_booking_id, v_total, UPPER(p_method));

  UPDATE events SET available_seats = available_seats - p_qty
  WHERE event_id = p_event_id;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Booking #' || p_booking_id || ' confirmed: ' || p_qty ||
                       ' ticket(s) for "' || v_title || '" | ' || v_user ||
                       ' | Paid Rs. ' || v_total);
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    ROLLBACK;
    p_booking_id := NULL;
    DBMS_OUTPUT.PUT_LINE('Error: Invalid user id ya event id.');
  WHEN e_bad_qty THEN
    ROLLBACK;
    p_booking_id := NULL;
    DBMS_OUTPUT.PUT_LINE('Error: Ek booking me 1 se 6 tickets hi le sakte hain.');
  WHEN e_closed THEN
    ROLLBACK;
    p_booking_id := NULL;
    DBMS_OUTPUT.PUT_LINE('Error: Is event ki booking band hai (cancelled/completed/past).');
  WHEN e_no_seats THEN
    ROLLBACK;
    p_booking_id := NULL;
    DBMS_OUTPUT.PUT_LINE('Error: Itni seats available nahi hain.');
END book_ticket;
/

-- ---------- 6. PROCEDURE : booking cancel + refund policy ----------
--   event se 48+ ghante pehle  -> 100% refund
--   24 se 48 ghante pehle      -> 50% refund
--   24 ghante se kam           -> cancel nahi ho sakti
CREATE OR REPLACE PROCEDURE cancel_booking (p_booking_id IN NUMBER) IS
  v_event_id   bookings.event_id%TYPE;
  v_qty        bookings.num_tickets%TYPE;
  v_total      bookings.total_amount%TYPE;
  v_status     bookings.status%TYPE;
  v_event_date events.event_date%TYPE;
  v_hours      NUMBER;
  v_refund     NUMBER;
BEGIN
  SELECT b.event_id, b.num_tickets, b.total_amount, b.status, e.event_date
  INTO   v_event_id, v_qty, v_total, v_status, v_event_date
  FROM   bookings b JOIN events e ON e.event_id = b.event_id
  WHERE  b.booking_id = p_booking_id
  FOR UPDATE OF b.status;

  IF v_status = 'CANCELLED' THEN
    DBMS_OUTPUT.PUT_LINE('Ye booking pehle hi cancel ho chuki hai.');
    ROLLBACK;
    RETURN;
  END IF;

  v_hours := (v_event_date - SYSDATE) * 24;

  IF v_hours < 24 THEN
    DBMS_OUTPUT.PUT_LINE('Error: Event ke 24 ghante ke andar cancellation allowed nahi hai.');
    ROLLBACK;
    RETURN;
  ELSIF v_hours >= 48 THEN
    v_refund := v_total;
  ELSE
    v_refund := ROUND(v_total * 0.50, 2);
  END IF;

  UPDATE bookings
  SET status = 'CANCELLED', refund_amount = v_refund
  WHERE booking_id = p_booking_id;

  UPDATE events SET available_seats = available_seats + v_qty
  WHERE event_id = v_event_id;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Booking #' || p_booking_id || ' cancelled. Refund: Rs. ' || v_refund);
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    ROLLBACK;
    DBMS_OUTPUT.PUT_LINE('Error: Invalid booking id.');
END cancel_booking;
/

-- ---------- 7. PROCEDURE : event-wise sales report (CURSOR) ----------
CREATE OR REPLACE PROCEDURE event_sales_report IS
  CURSOR c_sales IS
    SELECT e.event_id, e.title,
           NVL(SUM(CASE WHEN b.status = 'CONFIRMED' THEN b.num_tickets END), 0)  AS sold,
           NVL(SUM(CASE WHEN b.status = 'CONFIRMED' THEN b.total_amount END), 0) AS revenue
    FROM   events e LEFT JOIN bookings b ON b.event_id = e.event_id
    GROUP  BY e.event_id, e.title
    ORDER  BY revenue DESC;
  v_grand NUMBER := 0;
BEGIN
  DBMS_OUTPUT.PUT_LINE('--- EVENT SALES REPORT ---');
  FOR r IN c_sales LOOP
    DBMS_OUTPUT.PUT_LINE('#' || r.event_id || ' | ' || r.title ||
                         ' | Tickets sold: ' || r.sold || ' | Revenue: Rs. ' || r.revenue);
    v_grand := v_grand + r.revenue;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('TOTAL REVENUE: Rs. ' || v_grand);
END event_sales_report;
/

-- ---------- 8. VIEWS (frontend ke liye) ----------
CREATE OR REPLACE VIEW v_event_listing AS
SELECT e.event_id, e.title, e.category, e.event_date, e.ticket_price,
       v.name AS venue, v.city,
       e.total_seats, e.available_seats,
       (e.total_seats - e.available_seats) AS seats_booked,
       e.status
FROM   events e JOIN venues v ON v.venue_id = e.venue_id;

CREATE OR REPLACE VIEW v_booking_details AS
SELECT b.booking_id, u.name AS customer, e.title AS event,
       e.event_date, b.num_tickets, b.total_amount,
       b.status, b.refund_amount, b.booking_date
FROM   bookings b
JOIN   users  u ON u.user_id  = b.user_id
JOIN   events e ON e.event_id = b.event_id;

-- ---------- 9. SAMPLE DATA ----------
INSERT INTO users (name, email, phone) VALUES ('Aarav Mehta', 'aarav@example.com', '9876500001');
INSERT INTO users (name, email, phone) VALUES ('Simran Kaur', 'simran@example.com', '9876500002');
INSERT INTO users (name, email, phone) VALUES ('Rohan Verma', 'rohan@example.com', '9876500003');

INSERT INTO venues (name, city, capacity) VALUES ('City Convention Hall', 'Chandigarh', 800);
INSERT INTO venues (name, city, capacity) VALUES ('Open Air Arena',       'Ludhiana',   2000);
INSERT INTO venues (name, city, capacity) VALUES ('Tech Park Auditorium', 'Mohali',     300);

INSERT INTO events (title, category, description, venue_id, event_date, ticket_price, total_seats)
VALUES ('Punjab Music Fest', 'Music', 'Live concert with top artists', 2, SYSDATE + 15, 799, 100);
INSERT INTO events (title, category, description, venue_id, event_date, ticket_price, total_seats)
VALUES ('DevConnect 2026', 'Tech', 'One-day developer conference', 3, SYSDATE + 10, 499, 50);
INSERT INTO events (title, category, description, venue_id, event_date, ticket_price, total_seats)
VALUES ('Stand-up Comedy Night', 'Comedy', 'An evening of laughs', 1, SYSDATE + 5, 350, 5);
INSERT INTO events (title, category, description, venue_id, event_date, ticket_price, total_seats)
VALUES ('Startup Pitch Day', 'Business', 'Founders pitch to investors', 1, SYSDATE + 1.5, 250, 80);
COMMIT;

-- ---------- 10. TESTING ----------
SET SERVEROUTPUT ON

DECLARE
  v_id NUMBER;
BEGIN
  book_ticket(1, 1, 2, 'UPI',  v_id);   -- normal booking
  book_ticket(2, 2, 4, 'CARD', v_id);   -- 4 tickets -> 10% discount
  book_ticket(3, 3, 5, 'UPI',  v_id);   -- Comedy Night: saari 5 seats
  book_ticket(1, 3, 1, 'UPI',  v_id);   -- seats full -> error
  book_ticket(2, 1, 9, 'UPI',  v_id);   -- 9 tickets -> error
END;
/

EXEC cancel_booking(1001);   -- 15 din baad ka event -> 100% refund
EXEC event_sales_report;

SELECT * FROM v_event_listing;
SELECT * FROM v_booking_details;

-- Event cancel karke trigger test karo:
-- UPDATE events SET status = 'CANCELLED' WHERE event_id = 2;
-- SELECT * FROM v_booking_details;
