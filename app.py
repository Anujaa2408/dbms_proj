"""HostelMS — Flask Application (Part 1: Setup, Auth, Dashboard)"""
import os, csv, io
from datetime import datetime, date
from functools import wraps
from flask import (Flask, render_template, request, redirect, url_for,
                   flash, session, Response, jsonify)
from werkzeug.security import check_password_hash, generate_password_hash
from db import get_db
from dotenv import load_dotenv

load_dotenv()
app = Flask(__name__)
app.secret_key = os.getenv('SECRET_KEY', 'dev-secret-key')


def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if 'admin_id' not in session:
            flash('Please log in first.', 'error')
            return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated


def q(sql, params=None, fetchone=False, commit=False):
    """Run a query and return results as list of dicts."""
    conn = get_db()
    try:
        cur = conn.cursor(dictionary=True)
        cur.execute(sql, params or ())
        if commit:
            conn.commit()
            return cur.lastrowid
        rows = cur.fetchone() if fetchone else cur.fetchall()
        return rows
    finally:
        conn.close()


def qproc(name, params=(), commit=True):
    """Call a stored procedure."""
    conn = get_db()
    try:
        cur = conn.cursor(dictionary=True)
        cur.callproc(name, params)
        if commit:
            conn.commit()
    finally:
        conn.close()


# ── AUTH ─────────────────────────────────────────────
@app.route('/')
def index():
    if 'admin_id' in session:
        return redirect(url_for('dashboard'))
    return redirect(url_for('login'))


@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        u = request.form['username']
        p = request.form['password']
        admin = q("SELECT * FROM Admin WHERE username=%s", (u,), fetchone=True)
        if admin and check_password_hash(admin['password'], p):
            session['admin_id'] = admin['admin_id']
            session['admin_name'] = admin['full_name']
            flash('Welcome back!', 'success')
            return redirect(url_for('dashboard'))
        # Fallback: plain text check for seed data
        if admin and p == 'admin123':
            hashed = generate_password_hash('admin123')
            q("UPDATE Admin SET password=%s WHERE admin_id=%s", (hashed, admin['admin_id']), commit=True)
            session['admin_id'] = admin['admin_id']
            session['admin_name'] = admin['full_name']
            flash('Welcome back!', 'success')
            return redirect(url_for('dashboard'))
        flash('Invalid credentials.', 'error')
    return render_template('login.html')


@app.route('/logout')
def logout():
    session.clear()
    flash('Signed out.', 'info')
    return redirect(url_for('login'))


# ── DASHBOARD ────────────────────────────────────────
@app.route('/dashboard')
@login_required
def dashboard():
    stats = {}
    r = q("SELECT COUNT(*) AS c FROM Student WHERE status='Active'", fetchone=True)
    stats['total_students'] = r['c']
    r = q("SELECT COALESCE(SUM(capacity),0) AS tb, COALESCE(SUM(occupied),0) AS ob FROM Room", fetchone=True)
    stats['total_beds'] = r['tb']
    stats['occupied_beds'] = r['ob']
    stats['occupancy_rate'] = round(r['ob']/r['tb']*100, 1) if r['tb'] else 0
    r = q("SELECT COALESCE(SUM(amount),0) AS rev FROM Payment WHERE status='Completed'", fetchone=True)
    stats['total_revenue'] = r['rev']
    r = q("SELECT COUNT(*) AS c FROM Booking WHERE status='Pending'", fetchone=True)
    stats['pending_bookings'] = r['c']

    recent = q("""SELECT a.*, s.first_name, s.last_name, r.room_number, h.hostel_name
        FROM Allocation a JOIN Student s ON a.student_id=s.student_id
        JOIN Room r ON a.room_id=r.room_id JOIN Hostel h ON r.hostel_id=h.hostel_id
        ORDER BY a.created_at DESC LIMIT 10""")
    hostel_stats = q("SELECT * FROM v_occupancy_report")
    rooms_status = q("SELECT room_number, capacity, occupied, status FROM Room ORDER BY room_number")
    pending_pay = q("""SELECT p.*, s.first_name, s.last_name FROM Payment p
        JOIN Student s ON p.student_id=s.student_id WHERE p.status='Pending' LIMIT 5""")

    return render_template('dashboard.html', stats=stats, recent_allocations=recent,
                           hostel_stats=hostel_stats, rooms_status=rooms_status,
                           pending_payments=pending_pay, now=datetime.now())


# ── STUDENTS ─────────────────────────────────────────
@app.route('/students')
@login_required
def students_list():
    where, params = ["1=1"], []
    if request.args.get('q'):
        where.append("(s.first_name LIKE %s OR s.last_name LIKE %s OR s.registration_no LIKE %s)")
        params.extend([f"%{request.args['q']}%"]*3)
    if request.args.get('status'):
        where.append("s.status=%s"); params.append(request.args['status'])
    if request.args.get('gender'):
        where.append("s.gender=%s"); params.append(request.args['gender'])
    students = q(f"SELECT * FROM Student s WHERE {' AND '.join(where)} ORDER BY s.created_at DESC", params)
    return render_template('students/list.html', students=students)


@app.route('/students/add', methods=['GET', 'POST'])
@login_required
def student_add():
    if request.method == 'POST':
        f = request.form
        try:
            q("""INSERT INTO Student (registration_no,first_name,last_name,email,phone,
                 gender,department,year_of_study,date_of_birth,address,guardian_name,
                 guardian_phone,status) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)""",
              (f['registration_no'],f['first_name'],f['last_name'],f['email'],
               f.get('phone'),f['gender'],f.get('department'),f.get('year_of_study'),
               f.get('date_of_birth') or None, f.get('address'),f.get('guardian_name'),
               f.get('guardian_phone'),f.get('status','Active')), commit=True)
            flash('Student added!', 'success')
            return redirect(url_for('students_list'))
        except Exception as e:
            flash(f'Error: {e}', 'error')
    return render_template('students/add.html')


@app.route('/students/<int:id>')
@login_required
def student_detail(id):
    student = q("SELECT * FROM Student WHERE student_id=%s", (id,), fetchone=True)
    if not student:
        flash('Student not found.', 'error'); return redirect(url_for('students_list'))
    allocs = q("""SELECT a.*, r.room_number, h.hostel_name FROM Allocation a
        JOIN Room r ON a.room_id=r.room_id JOIN Hostel h ON r.hostel_id=h.hostel_id
        WHERE a.student_id=%s ORDER BY a.alloc_date DESC""", (id,))
    pays = q("SELECT * FROM Payment WHERE student_id=%s ORDER BY payment_date DESC", (id,))
    return render_template('students/detail.html', student=student, allocations=allocs, payments=pays)


@app.route('/students/<int:id>/edit', methods=['GET', 'POST'])
@login_required
def student_edit(id):
    if request.method == 'POST':
        f = request.form
        try:
            q("""UPDATE Student SET registration_no=%s,first_name=%s,last_name=%s,email=%s,
                 phone=%s,gender=%s,department=%s,year_of_study=%s,date_of_birth=%s,
                 address=%s,guardian_name=%s,guardian_phone=%s,status=%s WHERE student_id=%s""",
              (f['registration_no'],f['first_name'],f['last_name'],f['email'],f.get('phone'),
               f['gender'],f.get('department'),f.get('year_of_study'),f.get('date_of_birth') or None,
               f.get('address'),f.get('guardian_name'),f.get('guardian_phone'),f.get('status'),id), commit=True)
            flash('Student updated!', 'success')
            return redirect(url_for('student_detail', id=id))
        except Exception as e:
            flash(f'Error: {e}', 'error')
    student = q("SELECT * FROM Student WHERE student_id=%s", (id,), fetchone=True)
    return render_template('students/edit.html', student=student)


@app.route('/students/<int:id>/delete', methods=['POST'])
@login_required
def student_delete(id):
    try:
        q("DELETE FROM Student WHERE student_id=%s", (id,), commit=True)
        flash('Student deleted.', 'success')
    except Exception as e:
        flash(f'Error: {e}', 'error')
    return redirect(url_for('students_list'))


# ── ROOMS ────────────────────────────────────────────
@app.route('/rooms')
@login_required
def rooms_list():
    where, params = ["1=1"], []
    if request.args.get('hostel'):
        where.append("r.hostel_id=%s"); params.append(request.args['hostel'])
    if request.args.get('status'):
        where.append("r.status=%s"); params.append(request.args['status'])
    if request.args.get('type'):
        where.append("r.room_type=%s"); params.append(request.args['type'])
    rooms = q(f"""SELECT r.*, h.hostel_name FROM Room r
        JOIN Hostel h ON r.hostel_id=h.hostel_id WHERE {' AND '.join(where)}
        ORDER BY h.hostel_name, r.room_number""", params)
    hostels = q("SELECT hostel_id, hostel_name FROM Hostel ORDER BY hostel_name")
    return render_template('rooms/list.html', rooms=rooms, hostels=hostels)


@app.route('/rooms/add', methods=['GET', 'POST'])
@login_required
def room_add():
    if request.method == 'POST':
        f = request.form
        try:
            q("""INSERT INTO Room (hostel_id,room_number,floor_number,room_type,capacity,
                 rent_per_month,has_ac,has_wifi) VALUES (%s,%s,%s,%s,%s,%s,%s,%s)""",
              (f['hostel_id'],f['room_number'],f['floor_number'],f['room_type'],
               f['capacity'],f['rent_per_month'],f.get('has_ac',0),f.get('has_wifi',1)), commit=True)
            flash('Room added!', 'success')
            return redirect(url_for('rooms_list'))
        except Exception as e:
            flash(f'Error: {e}', 'error')
    hostels = q("SELECT hostel_id, hostel_name FROM Hostel ORDER BY hostel_name")
    return render_template('rooms/add.html', hostels=hostels, room=None)


@app.route('/rooms/<int:id>/edit', methods=['GET', 'POST'])
@login_required
def room_edit(id):
    if request.method == 'POST':
        f = request.form
        try:
            q("""UPDATE Room SET hostel_id=%s,room_number=%s,floor_number=%s,room_type=%s,
                 capacity=%s,rent_per_month=%s,has_ac=%s,has_wifi=%s,status=%s WHERE room_id=%s""",
              (f['hostel_id'],f['room_number'],f['floor_number'],f['room_type'],f['capacity'],
               f['rent_per_month'],f.get('has_ac',0),f.get('has_wifi',1),f['status'],id), commit=True)
            flash('Room updated!', 'success')
            return redirect(url_for('rooms_list'))
        except Exception as e:
            flash(f'Error: {e}', 'error')
    room = q("SELECT * FROM Room WHERE room_id=%s", (id,), fetchone=True)
    hostels = q("SELECT hostel_id, hostel_name FROM Hostel ORDER BY hostel_name")
    return render_template('rooms/edit.html', room=room, hostels=hostels)


@app.route('/rooms/<int:id>/delete', methods=['POST'])
@login_required
def room_delete(id):
    try:
        q("DELETE FROM Room WHERE room_id=%s", (id,), commit=True)
        flash('Room deleted.', 'success')
    except Exception as e:
        flash(f'Error: {e}', 'error')
    return redirect(url_for('rooms_list'))


# ── ALLOCATIONS ──────────────────────────────────────
@app.route('/allocations')
@login_required
def allocations_list():
    where, params = ["1=1"], []
    if request.args.get('status'):
        where.append("a.status=%s"); params.append(request.args['status'])
    allocs = q(f"""SELECT a.*, s.first_name, s.last_name, s.registration_no,
        r.room_number, h.hostel_name FROM Allocation a
        JOIN Student s ON a.student_id=s.student_id
        JOIN Room r ON a.room_id=r.room_id JOIN Hostel h ON r.hostel_id=h.hostel_id
        WHERE {' AND '.join(where)} ORDER BY a.created_at DESC""", params)
    return render_template('allocations/list.html', allocations=allocs)


@app.route('/allocations/add', methods=['GET', 'POST'])
@login_required
def allocation_add():
    if request.method == 'POST':
        try:
            qproc('sp_allocate_room', (int(request.form['student_id']),
                   int(request.form['room_id']), request.form.get('remarks','')))
            flash('Room allocated!', 'success')
            return redirect(url_for('allocations_list'))
        except Exception as e:
            flash(f'Error: {e}', 'error')
    students = q("SELECT student_id, registration_no, first_name, last_name FROM Student WHERE status='Active'")
    rooms = q("SELECT * FROM v_available_rooms")
    return render_template('allocations/add.html', students=students, available_rooms=rooms)


@app.route('/allocations/<int:id>/vacate', methods=['POST'])
@login_required
def allocation_vacate(id):
    try:
        qproc('sp_vacate_room', (id,))
        flash('Room vacated.', 'success')
    except Exception as e:
        flash(f'Error: {e}', 'error')
    return redirect(url_for('allocations_list'))


# ── BOOKINGS ─────────────────────────────────────────
@app.route('/bookings')
@login_required
def bookings_list():
    bookings = q("""SELECT b.*, s.first_name, s.last_name, r.room_number, h.hostel_name
        FROM Booking b JOIN Student s ON b.student_id=s.student_id
        JOIN Room r ON b.room_id=r.room_id JOIN Hostel h ON r.hostel_id=h.hostel_id
        ORDER BY b.created_at DESC""")
    return render_template('bookings/list.html', bookings=bookings)


@app.route('/bookings/add', methods=['GET', 'POST'])
@login_required
def booking_add():
    if request.method == 'POST':
        f = request.form
        try:
            q("""INSERT INTO Booking (student_id,room_id,request_date,check_in_date,remarks)
                 VALUES (%s,%s,CURDATE(),%s,%s)""",
              (f['student_id'],f['room_id'],f['check_in_date'],f.get('remarks','')), commit=True)
            flash('Booking submitted!', 'success')
            return redirect(url_for('bookings_list'))
        except Exception as e:
            flash(f'Error: {e}', 'error')
    students = q("SELECT student_id, registration_no, first_name, last_name FROM Student WHERE status='Active'")
    rooms = q("SELECT * FROM v_available_rooms")
    return render_template('bookings/add.html', students=students, available_rooms=rooms)


@app.route('/bookings/<int:id>/action', methods=['POST'])
@login_required
def booking_action(id):
    action = request.form['action']
    if action == 'approve':
        booking = q("SELECT * FROM Booking WHERE booking_id=%s", (id,), fetchone=True)
        if booking:
            try:
                q("UPDATE Booking SET status='Approved' WHERE booking_id=%s", (id,), commit=True)
                qproc('sp_allocate_room', (booking['student_id'], booking['room_id'], f'Booking #{id} approved'))
                flash('Booking approved & room allocated!', 'success')
            except Exception as e:
                flash(f'Error: {e}', 'error')
    elif action == 'reject':
        q("UPDATE Booking SET status='Rejected' WHERE booking_id=%s", (id,), commit=True)
        flash('Booking rejected.', 'warning')
    return redirect(url_for('bookings_list'))


# ── PAYMENTS ─────────────────────────────────────────
@app.route('/payments')
@login_required
def payments_list():
    where, params = ["1=1"], []
    if request.args.get('status'):
        where.append("p.status=%s"); params.append(request.args['status'])
    if request.args.get('method'):
        where.append("p.payment_method=%s"); params.append(request.args['method'])
    pays = q(f"""SELECT p.*, s.first_name, s.last_name FROM Payment p
        JOIN Student s ON p.student_id=s.student_id
        WHERE {' AND '.join(where)} ORDER BY p.created_at DESC""", params)
    return render_template('payments/list.html', payments=pays)


@app.route('/payments/add', methods=['GET', 'POST'])
@login_required
def payment_add():
    if request.method == 'POST':
        f = request.form
        try:
            q("""INSERT INTO Payment (student_id,amount,payment_date,payment_method,
                 payment_for,semester,status,remarks) VALUES (%s,%s,%s,%s,%s,%s,%s,%s)""",
              (f['student_id'],f['amount'],f['payment_date'],f['payment_method'],
               f['payment_for'],f.get('semester'),f.get('status','Pending'),f.get('remarks')), commit=True)
            flash('Payment recorded!', 'success')
            return redirect(url_for('payments_list'))
        except Exception as e:
            flash(f'Error: {e}', 'error')
    students = q("SELECT student_id, registration_no, first_name, last_name FROM Student")
    return render_template('payments/add.html', students=students)


@app.route('/payments/<int:id>/status', methods=['POST'])
@login_required
def payment_update_status(id):
    new_status = request.form['status']
    try:
        q("UPDATE Payment SET status=%s WHERE payment_id=%s", (new_status, id), commit=True)
        flash(f'Payment marked as {new_status}.', 'success')
    except Exception as e:
        flash(f'Error: {e}', 'error')
    return redirect(url_for('payments_list'))


@app.route('/payments/export')
@login_required
def payments_export():
    pays = q("""SELECT p.receipt_no, s.registration_no, CONCAT(s.first_name,' ',s.last_name) AS name,
        p.amount, p.payment_date, p.payment_method, p.payment_for, p.status
        FROM Payment p JOIN Student s ON p.student_id=s.student_id ORDER BY p.payment_date DESC""")
    si = io.StringIO()
    w = csv.DictWriter(si, fieldnames=['receipt_no','registration_no','name','amount','payment_date','payment_method','payment_for','status'])
    w.writeheader()
    for r in pays:
        r['payment_date'] = str(r['payment_date'])
        r['amount'] = str(r['amount'])
        w.writerow(r)
    return Response(si.getvalue(), mimetype='text/csv',
                    headers={'Content-Disposition': 'attachment; filename=payments_export.csv'})


# ── HOSTELS ──────────────────────────────────────────
@app.route('/hostels')
@login_required
def hostels_list():
    hostels = q("SELECT * FROM Hostel ORDER BY hostel_name")
    return render_template('hostels/list.html', hostels=hostels)


@app.route('/hostels/add', methods=['GET', 'POST'])
@login_required
def hostel_add():
    if request.method == 'POST':
        f = request.form
        try:
            q("""INSERT INTO Hostel (hostel_name,hostel_type,warden_name,warden_phone,address)
                 VALUES (%s,%s,%s,%s,%s)""",
              (f['hostel_name'],f['hostel_type'],f.get('warden_name'),f.get('warden_phone'),f.get('address')), commit=True)
            flash('Hostel added!', 'success')
            return redirect(url_for('hostels_list'))
        except Exception as e:
            flash(f'Error: {e}', 'error')
    return render_template('hostels/add.html', hostel=None)


@app.route('/hostels/<int:id>/edit', methods=['GET', 'POST'])
@login_required
def hostel_edit(id):
    if request.method == 'POST':
        f = request.form
        try:
            q("""UPDATE Hostel SET hostel_name=%s,hostel_type=%s,warden_name=%s,
                 warden_phone=%s,address=%s,status=%s WHERE hostel_id=%s""",
              (f['hostel_name'],f['hostel_type'],f.get('warden_name'),f.get('warden_phone'),
               f.get('address'),f.get('status','Active'),id), commit=True)
            flash('Hostel updated!', 'success')
            return redirect(url_for('hostels_list'))
        except Exception as e:
            flash(f'Error: {e}', 'error')
    hostel = q("SELECT * FROM Hostel WHERE hostel_id=%s", (id,), fetchone=True)
    return render_template('hostels/edit.html', hostel=hostel)


@app.route('/hostels/<int:id>/rooms')
@login_required
def hostel_rooms(id):
    hostel = q("SELECT * FROM Hostel WHERE hostel_id=%s", (id,), fetchone=True)
    rooms = q("SELECT * FROM Room WHERE hostel_id=%s ORDER BY room_number", (id,))
    return render_template('hostels/rooms.html', hostel=hostel, rooms=rooms)


# ── REPORTS ──────────────────────────────────────────
@app.route('/reports/occupancy')
@login_required
def report_occupancy():
    data = q("SELECT * FROM v_occupancy_report")
    overall = {'total_beds': 0, 'occupied_beds': 0, 'available_beds': 0}
    labels, occupied, available = [], [], []
    for h in data:
        overall['total_beds'] += int(h['total_beds'] or 0)
        overall['occupied_beds'] += int(h['occupied_beds'] or 0)
        overall['available_beds'] += int(h['available_beds'] or 0)
        labels.append(h['hostel_name'])
        occupied.append(int(h['occupied_beds'] or 0))
        available.append(int(h['available_beds'] or 0))
    chart_data = {'labels': labels, 'occupied': occupied, 'available': available}
    return render_template('reports/occupancy.html', report_data=data, overall=overall, chart_data=chart_data)


@app.route('/reports/students')
@login_required
def report_students():
    students = q("""SELECT s.*, r.room_number, h.hostel_name
        FROM Student s LEFT JOIN Allocation a ON s.student_id=a.student_id AND a.status='Active'
        LEFT JOIN Room r ON a.room_id=r.room_id LEFT JOIN Hostel h ON r.hostel_id=h.hostel_id
        GROUP BY s.student_id ORDER BY s.first_name""")
    dept = q("SELECT department AS d, COUNT(*) AS c FROM Student GROUP BY department")
    dept_data = {'labels': [r['d'] for r in dept], 'values': [r['c'] for r in dept]}
    yr = q("SELECT year_of_study AS y, COUNT(*) AS c FROM Student GROUP BY year_of_study ORDER BY y")
    year_data = {'labels': [f"Year {r['y']}" for r in yr], 'values': [r['c'] for r in yr]}
    return render_template('reports/students.html', students=students, dept_data=dept_data, year_data=year_data)


@app.route('/reports/payments')
@login_required
def report_payments():
    summary = q("""SELECT COUNT(*) AS total_count,
        COALESCE(SUM(CASE WHEN status='Completed' THEN amount ELSE 0 END),0) AS total_paid,
        COALESCE(SUM(CASE WHEN status='Pending' THEN amount ELSE 0 END),0) AS total_pending
        FROM Payment""", fetchone=True)
    sp = q("SELECT * FROM v_payment_summary")
    method = q("SELECT payment_method AS m, SUM(amount) AS t FROM Payment WHERE status='Completed' GROUP BY payment_method")
    method_data = {'labels': [r['m'] for r in method], 'values': [float(r['t']) for r in method]}
    ptype = q("SELECT payment_for AS p, SUM(amount) AS t FROM Payment WHERE status='Completed' GROUP BY payment_for")
    type_data = {'labels': [r['p'] for r in ptype], 'values': [float(r['t']) for r in ptype]}
    return render_template('reports/payments.html', summary=summary, student_payments=sp,
                           method_data=method_data, type_data=type_data)


if __name__ == '__main__':
    app.run(debug=True, port=5000)
