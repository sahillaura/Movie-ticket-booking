"""
Flask backend for the Movie Ticket Booking System.
Serves index.html and exposes a JSON API that calls the PL/SQL package
MOVIE_PKG (created by movie_ticket_booking.sql).

Setup:
    pip install -r requirements.txt

    # Windows (PowerShell)
    $env:ORACLE_USER="your_user"
    $env:ORACLE_PASSWORD="your_password"
    $env:ORACLE_DSN="localhost:1521/XEPDB1"

    # Linux / macOS
    export ORACLE_USER=your_user ORACLE_PASSWORD=your_password ORACLE_DSN=localhost:1521/XEPDB1

Run:
    python app.py        ->  open http://127.0.0.1:5001
"""
import os
import re

import oracledb
from flask import Flask, jsonify, request, send_file

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
app = Flask(__name__, static_folder=None)   # only index.html is served, not the whole folder

SEAT_RE = re.compile(r"^[A-E](10|[1-9])$")
EMAIL_RE = re.compile(r"^\S+@\S+\.\S+$")
MAX_SEATS = 6


def get_conn():
    return oracledb.connect(
        user=os.environ["ORACLE_USER"],
        password=os.environ["ORACLE_PASSWORD"],
        dsn=os.environ["ORACLE_DSN"],
    )


def db_error(e):
    """Turn an Oracle error into a JSON response.
    Messages raised by our PL/SQL (ORA-20000 to ORA-20999) are safe to show;
    anything else is logged and hidden behind a generic message."""
    m = re.search(r"ORA-(\d{5}): ([^\n]*)", str(e))
    if m and 20000 <= int(m.group(1)) <= 20999:
        code = 409 if int(m.group(1)) in (20009, 20011) else 400
        return jsonify(error=m.group(2)), code
    app.logger.exception("Database error")
    return jsonify(error="Database error. Please try again."), 500


@app.route("/")
def home():
    return send_file(os.path.join(BASE_DIR, "index.html"))


@app.get("/api/movies")
def list_movies():
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT movie_id, title, genre, lang, duration_min, rating "
                    "FROM movies ORDER BY movie_id")
        rows = [{"id": r[0], "title": r[1], "genre": r[2], "lang": r[3],
                 "duration": r[4], "rating": r[5]} for r in cur.fetchall()]
    return jsonify(rows)


@app.get("/api/shows")
def list_shows():
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "SELECT s.show_id, s.movie_id, t.name, t.city, s.screen_no, "
            "       s.show_time, s.price, s.available_seats "
            "FROM shows s JOIN theatres t ON t.theatre_id = s.theatre_id "
            "WHERE s.show_time > SYSDATE ORDER BY s.show_time"
        )
        rows = [{"id": r[0], "movieId": r[1], "theatre": r[2], "city": r[3],
                 "screen": r[4], "time": r[5].strftime("%Y-%m-%dT%H:%M:%S"),
                 "price": float(r[6]), "available": r[7]} for r in cur.fetchall()]
    return jsonify(rows)


@app.get("/api/shows/<int:show_id>/seats")
def booked_seats(show_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT seat_no FROM booked_seats WHERE show_id = :s ORDER BY seat_no",
                    s=show_id)
        return jsonify(booked=[r[0] for r in cur.fetchall()])


@app.post("/api/bookings")
def create_booking():
    data = request.get_json(silent=True) or {}
    name = str(data.get("name", "")).strip()
    email = str(data.get("email", "")).strip().lower()
    phone = str(data.get("phone", "")).strip() or None
    seats = data.get("seats")

    try:
        show_id = int(data.get("showId"))
    except (TypeError, ValueError):
        return jsonify(error="Select a show"), 400
    if not name or not EMAIL_RE.match(email):
        return jsonify(error="Enter a valid name and email"), 400
    if not isinstance(seats, list) or not seats:
        return jsonify(error="Select at least one seat"), 400
    seats = sorted({str(s).strip().upper() for s in seats})
    if len(seats) > MAX_SEATS:
        return jsonify(error="Maximum %d seats per booking" % MAX_SEATS), 400
    if not all(SEAT_RE.match(s) for s in seats):
        return jsonify(error="Invalid seat number (valid: A1 to E10)"), 400

    try:
        with get_conn() as conn:
            cur = conn.cursor()

            # reuse the customer if this email is already registered
            cur.execute("SELECT customer_id FROM customers WHERE email = :e", e=email)
            row = cur.fetchone()
            if row:
                customer_id = row[0]
            else:
                out_c = cur.var(int)
                cur.callproc("movie_pkg.add_customer", [name, email, phone, out_c])
                customer_id = int(out_c.getvalue())

            out_b = cur.var(int)
            cur.callproc("movie_pkg.book_ticket",
                         [customer_id, show_id, ",".join(seats), out_b])
            booking_id = int(out_b.getvalue())

            cur.execute("SELECT total_amount FROM bookings WHERE booking_id = :b", b=booking_id)
            amount = float(cur.fetchone()[0])
            conn.commit()
            return jsonify(bookingId=booking_id, amount=amount, seats=seats), 201
    except oracledb.DatabaseError as e:
        return db_error(e)


@app.get("/api/bookings")
def my_bookings():
    email = request.args.get("email", "").strip().lower()
    if not EMAIL_RE.match(email):
        return jsonify(error="Enter a valid email"), 400

    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "SELECT b.booking_id, m.title, t.name, t.city, s.screen_no, s.show_time, "
            "       b.num_seats, b.total_amount, b.status, b.refund_amount, "
            "       (SELECT LISTAGG(bs.seat_no, ',') WITHIN GROUP (ORDER BY bs.seat_no) "
            "          FROM booked_seats bs WHERE bs.booking_id = b.booking_id) "
            "FROM bookings b "
            "JOIN customers c ON c.customer_id = b.customer_id "
            "JOIN shows     s ON s.show_id     = b.show_id "
            "JOIN movies    m ON m.movie_id    = s.movie_id "
            "JOIN theatres  t ON t.theatre_id  = s.theatre_id "
            "WHERE c.email = :e ORDER BY b.booking_id DESC", e=email)
        rows = [{"id": r[0], "movie": r[1], "theatre": r[2], "city": r[3], "screen": r[4],
                 "time": r[5].strftime("%Y-%m-%dT%H:%M:%S"), "numSeats": r[6],
                 "amount": float(r[7]), "status": r[8],
                 "refund": float(r[9]) if r[9] is not None else None,
                 "seats": r[10].split(",") if r[10] else []} for r in cur.fetchall()]
    return jsonify(rows)


@app.post("/api/bookings/<int:booking_id>/cancel")
def cancel(booking_id):
    data = request.get_json(silent=True) or {}
    email = str(data.get("email", "")).strip().lower()
    if not EMAIL_RE.match(email):
        return jsonify(error="Enter the email used for the booking"), 400

    try:
        with get_conn() as conn:
            cur = conn.cursor()
            # only the customer who made the booking may cancel it
            cur.execute(
                "SELECT 1 FROM bookings b JOIN customers c ON c.customer_id = b.customer_id "
                "WHERE b.booking_id = :b AND c.email = :e", b=booking_id, e=email)
            if cur.fetchone() is None:
                return jsonify(error="Booking not found for this email"), 404

            cur.callproc("movie_pkg.cancel_booking", [booking_id])
            cur.execute("SELECT refund_amount FROM bookings WHERE booking_id = :b", b=booking_id)
            refund = float(cur.fetchone()[0])
            conn.commit()
            return jsonify(refund=refund)
    except oracledb.DatabaseError as e:
        return db_error(e)


if __name__ == "__main__":
    app.run(debug=True, port=5001)
