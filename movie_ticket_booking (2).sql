/* ============================================================================
   MINI PROJECT : MOVIE TICKET BOOKING SYSTEM
   LANGUAGE     : Oracle PL/SQL
   CONCEPTS     : Tables & constraints, sequences, package (spec + body),
                  procedures, functions, cursors, exceptions, triggers,
                  transactions (COMMIT / ROLLBACK), row locking (FOR UPDATE)

   HOW TO RUN   : SQL*Plus / SQL Developer / Oracle Live SQL
                  SET SERVEROUTPUT ON;
                  @movie_ticket_booking.sql
   ============================================================================ */

SET SERVEROUTPUT ON SIZE UNLIMITED;

-- ----------------------------------------------------------------------------
-- 0. CLEAN-UP (ignore errors on first run)
-- ----------------------------------------------------------------------------
BEGIN
  FOR t IN (SELECT table_name FROM user_tables
            WHERE table_name IN ('BOOKING_AUDIT','SHOW_SEATS','BOOKINGS',
                                 'SHOWS','CUSTOMERS','THEATRES','MOVIES')) LOOP
    EXECUTE IMMEDIATE 'DROP TABLE ' || t.table_name || ' CASCADE CONSTRAINTS';
  END LOOP;
  FOR s IN (SELECT sequence_name FROM user_sequences
            WHERE sequence_name LIKE 'SEQ\_%' ESCAPE '\') LOOP
    EXECUTE IMMEDIATE 'DROP SEQUENCE ' || s.sequence_name;
  END LOOP;
END;
/

-- ----------------------------------------------------------------------------
-- 1. SEQUENCES
-- ----------------------------------------------------------------------------
CREATE SEQUENCE seq_movie    START WITH 1 INCREMENT BY 1;
CREATE SEQUENCE seq_theatre  START WITH 1 INCREMENT BY 1;
CREATE SEQUENCE seq_show     START WITH 1 INCREMENT BY 1;
CREATE SEQUENCE seq_customer START WITH 1 INCREMENT BY 1;
CREATE SEQUENCE seq_booking  START WITH 1000 INCREMENT BY 1;
CREATE SEQUENCE seq_audit    START WITH 1 INCREMENT BY 1;

-- ----------------------------------------------------------------------------
-- 2. TABLES
-- ----------------------------------------------------------------------------
CREATE TABLE movies (
  movie_id      NUMBER        PRIMARY KEY,
  title         VARCHAR2(100) NOT NULL,
  genre         VARCHAR2(30),
  language      VARCHAR2(20),
  duration_min  NUMBER(4)     CHECK (duration_min > 0)
);

CREATE TABLE theatres (
  theatre_id    NUMBER        PRIMARY KEY,
  name          VARCHAR2(80)  NOT NULL,
  city          VARCHAR2(40),
  total_seats   NUMBER(4)     CHECK (total_seats BETWEEN 1 AND 260)
);

CREATE TABLE shows (
  show_id          NUMBER        PRIMARY KEY,
  movie_id         NUMBER        NOT NULL REFERENCES movies(movie_id),
  theatre_id       NUMBER        NOT NULL REFERENCES theatres(theatre_id),
  show_time        DATE          NOT NULL,
  price            NUMBER(7,2)   NOT NULL CHECK (price > 0),
  available_seats  NUMBER(4)     DEFAULT 0
);

CREATE TABLE customers (
  customer_id   NUMBER        PRIMARY KEY,
  name          VARCHAR2(60)  NOT NULL,
  email         VARCHAR2(80)  UNIQUE NOT NULL,
  phone         VARCHAR2(15)
);

CREATE TABLE bookings (
  booking_id    NUMBER        PRIMARY KEY,
  customer_id   NUMBER        NOT NULL REFERENCES customers(customer_id),
  show_id       NUMBER        NOT NULL REFERENCES shows(show_id),
  booking_time  DATE          DEFAULT SYSDATE,
  total_amount  NUMBER(9,2)   DEFAULT 0,
  status        VARCHAR2(10)  DEFAULT 'CONFIRMED'
                CHECK (status IN ('CONFIRMED','CANCELLED'))
);

CREATE TABLE show_seats (
  show_id     NUMBER        NOT NULL REFERENCES shows(show_id),
  seat_no     VARCHAR2(5)   NOT NULL,
  status      VARCHAR2(10)  DEFAULT 'AVAILABLE'
              CHECK (status IN ('AVAILABLE','BOOKED')),
  booking_id  NUMBER        REFERENCES bookings(booking_id),
  CONSTRAINT pk_show_seats PRIMARY KEY (show_id, seat_no)
);

CREATE TABLE booking_audit (
  audit_id    NUMBER        PRIMARY KEY,
  booking_id  NUMBER,
  action      VARCHAR2(20),
  old_status  VARCHAR2(10),
  new_status  VARCHAR2(10),
  action_time DATE DEFAULT SYSDATE
);

-- ----------------------------------------------------------------------------
-- 3. TRIGGERS
-- ----------------------------------------------------------------------------
-- 3a. Do not allow a show to be scheduled in the past
CREATE OR REPLACE TRIGGER trg_show_future_only
BEFORE INSERT ON shows
FOR EACH ROW
BEGIN
  IF :NEW.show_time < SYSDATE THEN
    RAISE_APPLICATION_ERROR(-20001, 'Show time cannot be in the past.');
  END IF;
END;
/

-- 3b. Audit every booking creation / status change
CREATE OR REPLACE TRIGGER trg_booking_audit
AFTER INSERT OR UPDATE OF status ON bookings
FOR EACH ROW
BEGIN
  IF INSERTING THEN
    INSERT INTO booking_audit
    VALUES (seq_audit.NEXTVAL, :NEW.booking_id, 'CREATED', NULL, :NEW.status, SYSDATE);
  ELSIF :OLD.status <> :NEW.status THEN
    INSERT INTO booking_audit
    VALUES (seq_audit.NEXTVAL, :NEW.booking_id, 'STATUS_CHANGE',
            :OLD.status, :NEW.status, SYSDATE);
  END IF;
END;
/

-- ----------------------------------------------------------------------------
-- 4. PACKAGE SPECIFICATION
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PACKAGE movie_booking_pkg AS
  -- master data
  PROCEDURE add_movie   (p_title VARCHAR2, p_genre VARCHAR2,
                         p_language VARCHAR2, p_duration NUMBER);
  PROCEDURE add_theatre (p_name VARCHAR2, p_city VARCHAR2, p_total_seats NUMBER);
  PROCEDURE add_customer(p_name VARCHAR2, p_email VARCHAR2, p_phone VARCHAR2);
  PROCEDURE add_show    (p_movie_id NUMBER, p_theatre_id NUMBER,
                         p_show_time DATE, p_price NUMBER);

  -- booking operations
  PROCEDURE book_tickets  (p_customer_id NUMBER, p_show_id NUMBER,
                           p_seats VARCHAR2,   -- e.g. 'A1,A2,A3'
                           p_booking_id OUT NUMBER);
  PROCEDURE cancel_booking(p_booking_id NUMBER);

  -- helpers / reports
  FUNCTION  get_available_seats(p_show_id NUMBER) RETURN NUMBER;
  FUNCTION  calc_refund(p_booking_id NUMBER)      RETURN NUMBER;
  PROCEDURE show_seat_map (p_show_id NUMBER);
  PROCEDURE print_ticket  (p_booking_id NUMBER);
  PROCEDURE list_shows;
  PROCEDURE revenue_report;
END movie_booking_pkg;
/

-- ----------------------------------------------------------------------------
-- 5. PACKAGE BODY
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PACKAGE BODY movie_booking_pkg AS

  ---------------------------------------------------------------- add_movie
  PROCEDURE add_movie(p_title VARCHAR2, p_genre VARCHAR2,
                      p_language VARCHAR2, p_duration NUMBER) IS
  BEGIN
    INSERT INTO movies VALUES (seq_movie.NEXTVAL, p_title, p_genre,
                               p_language, p_duration);
    COMMIT;
  END add_movie;

  -------------------------------------------------------------- add_theatre
  PROCEDURE add_theatre(p_name VARCHAR2, p_city VARCHAR2, p_total_seats NUMBER) IS
  BEGIN
    INSERT INTO theatres VALUES (seq_theatre.NEXTVAL, p_name, p_city, p_total_seats);
    COMMIT;
  END add_theatre;

  ------------------------------------------------------------- add_customer
  PROCEDURE add_customer(p_name VARCHAR2, p_email VARCHAR2, p_phone VARCHAR2) IS
  BEGIN
    INSERT INTO customers VALUES (seq_customer.NEXTVAL, p_name, p_email, p_phone);
    COMMIT;
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      DBMS_OUTPUT.PUT_LINE('Customer with email ' || p_email || ' already exists.');
  END add_customer;

  ---------------------------------------------------------------- add_show
  -- Creates the show AND generates its seat layout (10 seats per row: A1..A10, B1..)
  PROCEDURE add_show(p_movie_id NUMBER, p_theatre_id NUMBER,
                     p_show_time DATE, p_price NUMBER) IS
    v_total   theatres.total_seats%TYPE;
    v_show_id shows.show_id%TYPE := seq_show.NEXTVAL;
  BEGIN
    SELECT total_seats INTO v_total FROM theatres WHERE theatre_id = p_theatre_id;

    INSERT INTO shows (show_id, movie_id, theatre_id, show_time, price, available_seats)
    VALUES (v_show_id, p_movie_id, p_theatre_id, p_show_time, p_price, v_total);

    FOR i IN 1 .. v_total LOOP
      INSERT INTO show_seats (show_id, seat_no)
      VALUES (v_show_id, CHR(64 + CEIL(i / 10)) || (MOD(i - 1, 10) + 1));
    END LOOP;
    COMMIT;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      ROLLBACK;
      RAISE_APPLICATION_ERROR(-20002, 'Theatre not found.');
  END add_show;

  ------------------------------------------------------- get_available_seats
  FUNCTION get_available_seats(p_show_id NUMBER) RETURN NUMBER IS
    v_cnt NUMBER;
  BEGIN
    SELECT COUNT(*) INTO v_cnt
      FROM show_seats
     WHERE show_id = p_show_id AND status = 'AVAILABLE';
    RETURN v_cnt;
  END get_available_seats;

  ------------------------------------------------------------- book_tickets
  PROCEDURE book_tickets(p_customer_id NUMBER, p_show_id NUMBER,
                         p_seats VARCHAR2, p_booking_id OUT NUMBER) IS
    v_price     shows.price%TYPE;
    v_show_time shows.show_time%TYPE;
    v_cust_cnt  NUMBER;
    v_status    show_seats.status%TYPE;
    v_seat      VARCHAR2(10);
    v_count     NUMBER := 0;
    i           NUMBER := 1;
  BEGIN
    -- validate customer
    SELECT COUNT(*) INTO v_cust_cnt FROM customers WHERE customer_id = p_customer_id;
    IF v_cust_cnt = 0 THEN
      RAISE_APPLICATION_ERROR(-20010, 'Invalid customer id.');
    END IF;

    -- validate show
    BEGIN
      SELECT price, show_time INTO v_price, v_show_time
        FROM shows WHERE show_id = p_show_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20011, 'Invalid show id.');
    END;

    IF v_show_time < SYSDATE THEN
      RAISE_APPLICATION_ERROR(-20012, 'This show has already started/ended.');
    END IF;

    -- create the booking header
    p_booking_id := seq_booking.NEXTVAL;
    INSERT INTO bookings (booking_id, customer_id, show_id)
    VALUES (p_booking_id, p_customer_id, p_show_id);

    -- process each requested seat (lock row so two users cannot take same seat)
    LOOP
      v_seat := UPPER(TRIM(REGEXP_SUBSTR(p_seats, '[^,]+', 1, i)));
      EXIT WHEN v_seat IS NULL;

      BEGIN
        SELECT status INTO v_status
          FROM show_seats
         WHERE show_id = p_show_id AND seat_no = v_seat
           FOR UPDATE;
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          RAISE_APPLICATION_ERROR(-20013, 'Seat ' || v_seat || ' does not exist.');
      END;

      IF v_status = 'BOOKED' THEN
        RAISE_APPLICATION_ERROR(-20014, 'Seat ' || v_seat || ' is already booked.');
      END IF;

      UPDATE show_seats
         SET status = 'BOOKED', booking_id = p_booking_id
       WHERE show_id = p_show_id AND seat_no = v_seat;

      v_count := v_count + 1;
      i := i + 1;
    END LOOP;

    IF v_count = 0 THEN
      RAISE_APPLICATION_ERROR(-20015, 'No seats selected.');
    END IF;

    UPDATE shows
       SET available_seats = available_seats - v_count
     WHERE show_id = p_show_id;

    UPDATE bookings
       SET total_amount = v_count * v_price
     WHERE booking_id = p_booking_id;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Booking successful! Booking ID: ' || p_booking_id ||
                         ' | Seats: ' || v_count ||
                         ' | Amount: Rs.' || v_count * v_price);
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;                      -- undo seats, booking header, everything
      p_booking_id := NULL;
      DBMS_OUTPUT.PUT_LINE('Booking failed: ' || SQLERRM);
  END book_tickets;

  -------------------------------------------------------------- calc_refund
  -- Refund policy: >24 hrs before show = 100%, 2-24 hrs = 50%, <2 hrs = 0%
  FUNCTION calc_refund(p_booking_id NUMBER) RETURN NUMBER IS
    v_amount  bookings.total_amount%TYPE;
    v_time    shows.show_time%TYPE;
    v_hours   NUMBER;
  BEGIN
    SELECT b.total_amount, s.show_time
      INTO v_amount, v_time
      FROM bookings b JOIN shows s ON s.show_id = b.show_id
     WHERE b.booking_id = p_booking_id;

    v_hours := (v_time - SYSDATE) * 24;

    RETURN CASE
             WHEN v_hours > 24 THEN v_amount
             WHEN v_hours >= 2 THEN v_amount * 0.5
             ELSE 0
           END;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN 0;
  END calc_refund;

  --------------------------------------------------------- cancel_booking
  PROCEDURE cancel_booking(p_booking_id NUMBER) IS
    v_status  bookings.status%TYPE;
    v_show_id bookings.show_id%TYPE;
    v_refund  NUMBER;
    v_freed   NUMBER;
  BEGIN
    SELECT status, show_id INTO v_status, v_show_id
      FROM bookings WHERE booking_id = p_booking_id FOR UPDATE;

    IF v_status = 'CANCELLED' THEN
      RAISE_APPLICATION_ERROR(-20020, 'Booking is already cancelled.');
    END IF;

    v_refund := calc_refund(p_booking_id);

    UPDATE show_seats
       SET status = 'AVAILABLE', booking_id = NULL
     WHERE booking_id = p_booking_id;
    v_freed := SQL%ROWCOUNT;

    UPDATE shows SET available_seats = available_seats + v_freed
     WHERE show_id = v_show_id;

    UPDATE bookings SET status = 'CANCELLED' WHERE booking_id = p_booking_id;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Booking ' || p_booking_id || ' cancelled. ' ||
                         v_freed || ' seat(s) released. Refund: Rs.' || v_refund);
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      DBMS_OUTPUT.PUT_LINE('Booking ID ' || p_booking_id || ' not found.');
    WHEN OTHERS THEN
      ROLLBACK;
      DBMS_OUTPUT.PUT_LINE('Cancellation failed: ' || SQLERRM);
  END cancel_booking;

  ---------------------------------------------------------- show_seat_map
  PROCEDURE show_seat_map(p_show_id NUMBER) IS
    CURSOR c_seats IS
      SELECT seat_no, status FROM show_seats
       WHERE show_id = p_show_id
       ORDER BY SUBSTR(seat_no,1,1), TO_NUMBER(SUBSTR(seat_no,2));
    v_line VARCHAR2(200);
    v_row  CHAR(1) := NULL;
  BEGIN
    DBMS_OUTPUT.PUT_LINE('--- Seat map for show ' || p_show_id ||
                         '  ([ ] free, [X] booked) ---');
    FOR r IN c_seats LOOP
      IF v_row IS NOT NULL AND v_row <> SUBSTR(r.seat_no,1,1) THEN
        DBMS_OUTPUT.PUT_LINE(v_line);
        v_line := NULL;
      END IF;
      v_row  := SUBSTR(r.seat_no,1,1);
      v_line := v_line || RPAD(r.seat_no,4) ||
                CASE r.status WHEN 'BOOKED' THEN '[X] ' ELSE '[ ] ' END;
    END LOOP;
    IF v_line IS NOT NULL THEN
      DBMS_OUTPUT.PUT_LINE(v_line);
    END IF;
  END show_seat_map;

  ------------------------------------------------------------- print_ticket
  PROCEDURE print_ticket(p_booking_id NUMBER) IS
    v_seats VARCHAR2(500);
  BEGIN
    FOR r IN (SELECT b.booking_id, c.name cust, m.title, t.name theatre, t.city,
                     s.show_time, b.total_amount, b.status
                FROM bookings b
                JOIN customers c ON c.customer_id = b.customer_id
                JOIN shows s     ON s.show_id     = b.show_id
                JOIN movies m    ON m.movie_id    = s.movie_id
                JOIN theatres t  ON t.theatre_id  = s.theatre_id
               WHERE b.booking_id = p_booking_id) LOOP

      SELECT LISTAGG(seat_no, ', ') WITHIN GROUP (ORDER BY seat_no)
        INTO v_seats FROM show_seats WHERE booking_id = p_booking_id;

      DBMS_OUTPUT.PUT_LINE('==============================================');
      DBMS_OUTPUT.PUT_LINE('            MOVIE TICKET');
      DBMS_OUTPUT.PUT_LINE('==============================================');
      DBMS_OUTPUT.PUT_LINE('Booking ID : ' || r.booking_id || '  (' || r.status || ')');
      DBMS_OUTPUT.PUT_LINE('Customer   : ' || r.cust);
      DBMS_OUTPUT.PUT_LINE('Movie      : ' || r.title);
      DBMS_OUTPUT.PUT_LINE('Theatre    : ' || r.theatre || ', ' || r.city);
      DBMS_OUTPUT.PUT_LINE('Show Time  : ' || TO_CHAR(r.show_time, 'DD-MON-YYYY HH24:MI'));
      DBMS_OUTPUT.PUT_LINE('Seats      : ' || NVL(v_seats, '-'));
      DBMS_OUTPUT.PUT_LINE('Amount     : Rs.' || r.total_amount);
      DBMS_OUTPUT.PUT_LINE('==============================================');
      RETURN;
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('Booking ID ' || p_booking_id || ' not found.');
  END print_ticket;

  ------------------------------------------------------------- list_shows
  PROCEDURE list_shows IS
    CURSOR c_shows IS
      SELECT s.show_id, m.title, t.name theatre, s.show_time, s.price,
             s.available_seats
        FROM shows s
        JOIN movies m   ON m.movie_id   = s.movie_id
        JOIN theatres t ON t.theatre_id = s.theatre_id
       WHERE s.show_time >= SYSDATE
       ORDER BY s.show_time;
  BEGIN
    DBMS_OUTPUT.PUT_LINE(RPAD('ID',5) || RPAD('MOVIE',26) || RPAD('THEATRE',20) ||
                         RPAD('TIME',19) || RPAD('PRICE',8) || 'FREE');
    DBMS_OUTPUT.PUT_LINE(RPAD('-',85,'-'));
    FOR r IN c_shows LOOP
      DBMS_OUTPUT.PUT_LINE(RPAD(r.show_id,5) || RPAD(r.title,26) ||
                           RPAD(r.theatre,20) ||
                           RPAD(TO_CHAR(r.show_time,'DD-MON-YY HH24:MI'),19) ||
                           RPAD(r.price,8) || r.available_seats);
    END LOOP;
  END list_shows;

  --------------------------------------------------------- revenue_report
  PROCEDURE revenue_report IS
    v_grand NUMBER := 0;
  BEGIN
    DBMS_OUTPUT.PUT_LINE('--- REVENUE REPORT (confirmed bookings) ---');
    FOR r IN (SELECT m.title, COUNT(b.booking_id) bookings,
                     NVL(SUM(b.total_amount),0) revenue
                FROM movies m
                LEFT JOIN shows s    ON s.movie_id = m.movie_id
                LEFT JOIN bookings b ON b.show_id  = s.show_id
                                    AND b.status   = 'CONFIRMED'
               GROUP BY m.title
               ORDER BY revenue DESC) LOOP
      DBMS_OUTPUT.PUT_LINE(RPAD(r.title,28) || ' Bookings: ' ||
                           RPAD(r.bookings,4) || ' Revenue: Rs.' || r.revenue);
      v_grand := v_grand + r.revenue;
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('TOTAL REVENUE: Rs.' || v_grand);
  END revenue_report;

END movie_booking_pkg;
/

SHOW ERRORS

-- ----------------------------------------------------------------------------
-- 6. SAMPLE DATA
-- ----------------------------------------------------------------------------
BEGIN
  movie_booking_pkg.add_movie('Inception',          'Sci-Fi', 'English', 148);
  movie_booking_pkg.add_movie('3 Idiots',           'Comedy', 'Hindi',   170);
  movie_booking_pkg.add_movie('Avengers: Endgame',  'Action', 'English', 181);

  movie_booking_pkg.add_theatre('PVR Cinemas',   'Rohtak', 30);
  movie_booking_pkg.add_theatre('Cineplex Mall', 'Rohtak', 20);

  movie_booking_pkg.add_customer('Rahul Sharma', 'rahul@example.com', '9876543210');
  movie_booking_pkg.add_customer('Priya Singh',  'priya@example.com', '9123456780');
  movie_booking_pkg.add_customer('Amit Verma',   'amit@example.com',  '9988776655');

  -- shows: (movie, theatre, time, price)
  movie_booking_pkg.add_show(1, 1, SYSDATE + 2,        250);  -- >24h away
  movie_booking_pkg.add_show(2, 1, SYSDATE + 1/6,      200);  -- ~4h away
  movie_booking_pkg.add_show(3, 2, SYSDATE + 3,        300);
END;
/

-- ----------------------------------------------------------------------------
-- 7. DEMO / TEST SCRIPT
-- ----------------------------------------------------------------------------
DECLARE
  v_b1 NUMBER;
  v_b2 NUMBER;
  v_b3 NUMBER;
BEGIN
  DBMS_OUTPUT.PUT_LINE('>>> AVAILABLE SHOWS');
  movie_booking_pkg.list_shows;

  DBMS_OUTPUT.PUT_LINE(CHR(10) || '>>> TEST 1: Valid booking');
  movie_booking_pkg.book_tickets(1, 1, 'A1,A2,A3', v_b1);

  DBMS_OUTPUT.PUT_LINE(CHR(10) || '>>> TEST 2: Same seat again (should fail)');
  movie_booking_pkg.book_tickets(2, 1, 'A3,A4', v_b2);

  DBMS_OUTPUT.PUT_LINE(CHR(10) || '>>> TEST 3: Invalid seat (should fail)');
  movie_booking_pkg.book_tickets(2, 1, 'Z99', v_b2);

  DBMS_OUTPUT.PUT_LINE(CHR(10) || '>>> TEST 4: Another valid booking');
  movie_booking_pkg.book_tickets(2, 1, 'B5,B6', v_b2);

  DBMS_OUTPUT.PUT_LINE(CHR(10) || '>>> TEST 5: Booking for show 2');
  movie_booking_pkg.book_tickets(3, 2, 'C1,C2', v_b3);

  DBMS_OUTPUT.PUT_LINE(CHR(10) || '>>> TICKET');
  movie_booking_pkg.print_ticket(v_b1);

  DBMS_OUTPUT.PUT_LINE(CHR(10) || '>>> SEAT MAP (show 1)');
  movie_booking_pkg.show_seat_map(1);

  DBMS_OUTPUT.PUT_LINE(CHR(10) || '>>> CANCEL booking ' || v_b1 || ' (100% refund)');
  movie_booking_pkg.cancel_booking(v_b1);

  DBMS_OUTPUT.PUT_LINE(CHR(10) || '>>> CANCEL booking ' || v_b3 || ' (50% refund)');
  movie_booking_pkg.cancel_booking(v_b3);

  DBMS_OUTPUT.PUT_LINE(CHR(10) || '>>> CANCEL again (should fail)');
  movie_booking_pkg.cancel_booking(v_b3);

  DBMS_OUTPUT.PUT_LINE(CHR(10) || '>>> FREE SEATS IN SHOW 1: ' ||
                       movie_booking_pkg.get_available_seats(1));

  DBMS_OUTPUT.PUT_LINE(CHR(10));
  movie_booking_pkg.revenue_report;
END;
/

-- Audit trail produced by the trigger
SELECT * FROM booking_audit ORDER BY audit_id;
