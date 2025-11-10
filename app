# RELAY SETTINGS ASSISTANT - Main Application File
# Copy this entire code into app.py and run: streamlit run app.py

import streamlit as st
from streamlit_option_menu import option_menu
import json, os, math, sqlite3, hashlib
from datetime import datetime
from pathlib import Path

# PAGE CONFIG
st.set_page_config(page_title="Relay Settings Assistant", page_icon="⚡", layout="wide", initial_sidebar_state="collapsed")

# STYLING
st.markdown("""
<style>
[data-testid="stMetricValue"] { font-size: 28px; }
.header-title { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 25px; 
    border-radius: 10px; text-align: center; font-size: 28px; font-weight: bold; margin-bottom: 20px; }
.recommended-value { background: #e8f5e9; padding: 12px; border-radius: 5px; border-left: 4px solid #4caf50; margin: 5px 0; }
.info-box { background: #fff3cd; padding: 12px; border-radius: 5px; border-left: 4px solid #ffc107; margin: 10px 0; }
</style>
""", unsafe_allow_html=True)

# SESSION STATE
if "logged_in" not in st.session_state:
    st.session_state.logged_in = False
if "username" not in st.session_state:
    st.session_state.username = None
if "current_project" not in st.session_state:
    st.session_state.current_project = None
if "calculations" not in st.session_state:
    st.session_state.calculations = {}
if "transformer_data" not in st.session_state:
    st.session_state.transformer_data = {}
if "ct_data" not in st.session_state:
    st.session_state.ct_data = {}

# DATABASE FUNCTIONS
def init_database():
    db_path = Path("data/relay_settings.db")
    db_path.parent.mkdir(exist_ok=True)
    conn = sqlite3.connect(str(db_path))
    cursor = conn.cursor()
    cursor.execute("CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, username TEXT UNIQUE NOT NULL, password_hash TEXT NOT NULL)")
    cursor.execute("CREATE TABLE IF NOT EXISTS projects (id INTEGER PRIMARY KEY, project_id TEXT UNIQUE NOT NULL, user_id INTEGER, project_name TEXT, engineer_name TEXT, transformer_data JSON, ct_data JSON)")
    conn.commit()
    conn.close()

def hash_password(password):
    return hashlib.sha256(password.encode()).hexdigest()

def register_user(username, password):
    try:
        conn = sqlite3.connect("data/relay_settings.db")
        cursor = conn.cursor()
        cursor.execute("INSERT INTO users (username, password_hash) VALUES (?, ?)", (username, hash_password(password)))
        conn.commit()
        conn.close()
        return True
    except:
        return False

def authenticate_user(username, password):
    conn = sqlite3.connect("data/relay_settings.db")
    cursor = conn.cursor()
    cursor.execute("SELECT id FROM users WHERE username = ? AND password_hash = ?", (username, hash_password(password)))
    user = cursor.fetchone()
    conn.close()
    return user is not None

# CALCULATION FUNCTIONS
def calculate_transformer_values(mva, hv_kv, lv_kv, impedance, ltc_present, ltc_range, mag_current):
    i_hv = (mva * 1000) / (math.sqrt(3) * hv_kv)
    i_lv = (mva * 1000) / (math.sqrt(3) * lv_kv)
    z_pu = impedance / 100
    i_max_fault_pu = 1 / z_pu
    category = "I" if mva < 0.5 else "II" if mva < 5 else "III" if mva < 30 else "IV"
    return {"hv_rated_current": round(i_hv, 2), "lv_rated_current": round(i_lv, 2), "max_through_fault_pu": round(i_max_fault_pu, 2), "category": category}

def calculate_differential_settings(mva, impedance, ltc_present, ltc_range, mag_current, hv_ct_ratio, lv_ct_ratio, base_values):
    ct_error = 0.10
    ltc_error = (ltc_range / 100) if ltc_present else 0
    mag_pct = mag_current / 100
    pickup_pu = round(min((ct_error + ltc_error + mag_pct + 0.05) * 1.1, 0.40), 2)
    slope_1 = 30 if ltc_present else 25
    return {
        "pickup_pu": {"recommended": pickup_pu, "value_set": None, "unit": "pu", "standard_ref": "IEEE C37.91-2021 Cl 5.3.4"},
        "slope_1": {"recommended": slope_1, "value_set": None, "unit": "%", "standard_ref": "IEEE C37.91-2021 Cl 5.3.5"},
        "slope_2": {"recommended": 60, "value_set": None, "unit": "%", "standard_ref": "IEEE C37.91-2021 Cl 5.3.6"},
        "harmonic_2nd": {"recommended": 15, "value_set": None, "unit": "%", "standard_ref": "IEC 60255-187-1 Cl 6.6.2"},
        "harmonic_5th": {"recommended": 35, "value_set": None, "unit": "%", "standard_ref": "IEC 60255-187-1 Cl 6.6.2"},
        "high_set": {"recommended": 10.0 if base_values["max_through_fault_pu"] < 12 else 12.0, "value_set": None, "unit": "pu", "standard_ref": "IEEE C37.91-2021 Cl 5.3.7"}
    }

def calculate_overcurrent_settings(mva, impedance, hv_kv, lv_kv, hv_fault_mva, lv_fault_mva, base_values):
    i_hv_rated = base_values["hv_rated_current"]
    pickup_hv = 1.25
    i_fault_hv = (hv_fault_mva * 1000) / (math.sqrt(3) * hv_kv)
    psm_hv = i_fault_hv / (pickup_hv * i_hv_rated) if i_fault_hv > 0 else 1
    tms_hv = 0.2
    trip_time_hv = tms_hv * 0.14 / ((psm_hv ** 0.02) - 1) if psm_hv > 1 else 999
    
    i_lv_rated = base_values["lv_rated_current"]
    i_fault_lv = (lv_fault_mva * 1000) / (math.sqrt(3) * lv_kv)
    psm_lv = i_fault_lv / (1.25 * i_lv_rated) if i_fault_lv > 0 else 1
    tms_lv = 0.1
    trip_time_lv = tms_lv * 0.14 / ((psm_lv ** 0.02) - 1) if psm_lv > 1 else 999
    
    return {
        "hv_51": {"pickup": 1.25, "tms": tms_hv, "trip_time": round(trip_time_hv, 2)},
        "lv_51": {"pickup": 1.25, "tms": tms_lv, "trip_time": round(trip_time_lv, 2)},
        "coordination_margin": round(trip_time_hv - trip_time_lv, 3),
        "coordination_status": "✅ PASS" if (trip_time_hv - trip_time_lv) >= 0.3 else "❌ FAIL"
    }

def calculate_i2t_settings(mva, base_values, max_through_fault_pu):
    category = base_values["category"]
    i2t_thermal = 1250
    i2t_mechanical = (max_through_fault_pu ** 2) * 2 if category in ["III", "IV"] else 2000
    i2t_limit = min(i2t_thermal, i2t_mechanical)
    return {
        "category": category,
        "thermal_limit": i2t_thermal,
        "mechanical_limit": round(i2t_mechanical, 0),
        "alarm_threshold": round(i2t_limit * 0.8, 0),
        "trip_threshold": round(i2t_limit * 0.95, 0)
    }

# LOGIN PAGE
def login_page():
    col1, col2, col3 = st.columns([1, 1.5, 1])
    with col2:
        st.markdown("<h1 style='text-align: center; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); -webkit-background-clip: text; -webkit-text-fill-color: transparent;'>⚡ Relay Settings</h1>", unsafe_allow_html=True)
        st.markdown("<h2 style='text-align: center; color: #666;'>Transformer Protection Assistant</h2>", unsafe_allow_html=True)
        st.markdown("---")
        
        tab1, tab2 = st.tabs(["🔑 Login", "📝 Register"])
        
        with tab1:
            username = st.text_input("Username", placeholder="engineer@company.com", key="login_user")
            password = st.text_input("Password", type="password", placeholder="Enter password", key="login_pass")
            if st.button("🚀 Sign In", use_container_width=True):
                if username and password and authenticate_user(username, password):
                    st.session_state.logged_in = True
                    st.session_state.username = username
                    st.success("✅ Login successful!")
                    st.rerun()
                else:
                    st.error("❌ Invalid credentials")
            st.markdown("**Demo:** engineer@company.com / Test@123")
        
        with tab2:
            new_user = st.text_input("Username", placeholder="your.email@company.com", key="reg_user")
            new_pass = st.text_input("Password", type="password", placeholder="Min 6 chars", key="reg_pass")
            confirm_pass = st.text_input("Confirm", type="password", placeholder="Confirm password", key="reg_conf")
            if st.button("📝 Register", use_container_width=True):
                if new_user and new_pass == confirm_pass and len(new_pass) >= 6:
                    if register_user(new_user, new_pass):
                        st.success("✅ Account created! Login now.")
                    else:
                        st.error("❌ Username exists")
                else:
                    st.warning("⚠️ Check password & length")

# MAIN APP
def main_app():
    st.markdown('<div class="header-title">⚡ Relay Settings Assistant</div>', unsafe_allow_html=True)
    
    col1, col2, col3 = st.columns([1, 1, 0.2])
    with col3:
        if st.button("🚪 Logout", use_container_width=True):
            st.session_state.logged_in = False
            st.session_state.username = None
            st.rerun()
    
    st.markdown(f"**👤 User:** {st.session_state.username}")
    
    with st.sidebar:
        st.markdown("### 📋 Menu")
        selected = option_menu(None, ["🏠 Dashboard", "➕ New Project", "📊 Calculations", "📄 Reports", "⚙️ Settings"],
            icons=["house", "plus-circle", "graph-up", "file-earmark-pdf", "gear"], default_index=0)
    
    # DASHBOARD
    if selected == "🏠 Dashboard":
        st.markdown("## Welcome")
        col1, col2, col3, col4 = st.columns(4)
        with col1:
            st.metric("Projects", "0", "+0")
        with col2:
            st.metric("Completed", "0", "+0")
        with col3:
            st.metric("In Progress", "0", "+0")
        with col4:
            st.metric("Reports", "0", "+0")
        st.info("📖 Create projects to calculate relay settings based on IEEE C37.91 & IEEE 242 standards")
    
    # NEW PROJECT
    elif selected == "➕ New Project":
        st.markdown("## Create New Project")
        with st.form("project_form"):
            col1, col2 = st.columns(2)
            with col1:
                project_name = st.text_input("Project Name", value="Substation A - T1")
            with col2:
                engineer_name = st.text_input("Engineer Name", value=st.session_state.username)
            
            st.markdown("### Transformer Data")
            col1, col2, col3 = st.columns(3)
            with col1:
                rated_mva = st.number_input("Power (MVA)", min_value=1.0, value=50.0, step=5.0)
            with col2:
                hv_kv = st.number_input("HV (kV)", min_value=1.0, value=132.0, step=10.0)
            with col3:
                lv_kv = st.number_input("LV (kV)", min_value=0.1, value=33.0, step=1.0)
            
            col1, col2, col3 = st.columns(3)
            with col1:
                impedance = st.number_input("Impedance (%)", min_value=1.0, value=12.5, step=0.5)
            with col2:
                mag_current = st.number_input("Mag Current (%)", min_value=0.1, value=0.8, step=0.1)
            with col3:
                ltc_present = st.checkbox("LTC?", value=True)
                ltc_range = st.number_input("LTC Range (±%)", min_value=1.0, value=10.0) if ltc_present else 0
            
            st.markdown("### CT Configuration")
            col1, col2 = st.columns(2)
            with col1:
                hv_ct_ratio = float(st.text_input("HV CT Ratio", value="300/1").split("/")[0])
            with col2:
                lv_ct_ratio = float(st.text_input("LV CT Ratio", value="1000/1").split("/")[0])
            
            st.markdown("### System Data")
            col1, col2 = st.columns(2)
            with col1:
                hv_fault_mva = st.number_input("HV Fault (MVA)", min_value=100.0, value=5000.0, step=100.0)
            with col2:
                lv_fault_mva = st.number_input("LV Fault (MVA)", min_value=100.0, value=1500.0, step=100.0)
            
            if st.form_submit_button("✅ Calculate", use_container_width=True):
                st.session_state.transformer_data = {"rated_mva": rated_mva, "hv_kv": hv_kv, "lv_kv": lv_kv, "impedance": impedance, 
                    "mag_current": mag_current, "ltc_present": ltc_present, "ltc_range": ltc_range}
                st.session_state.ct_data = {"hv_ct_ratio": hv_ct_ratio, "lv_ct_ratio": lv_ct_ratio}
                st.session_state.system_data = {"hv_fault_mva": hv_fault_mva, "lv_fault_mva": lv_fault_mva}
                st.session_state.current_project = {"name": project_name, "engineer": engineer_name}
                st.success("✅ Project created!")
    
    # CALCULATIONS
    elif selected == "📊 Calculations":
        if not st.session_state.current_project:
            st.warning("⚠️ Create a project first")
        else:
            st.markdown(f"## {st.session_state.current_project['name']}")
            
            t_data = st.session_state.transformer_data
            c_data = st.session_state.ct_data
            s_data = st.session_state.system_data
            
            base_values = calculate_transformer_values(t_data["rated_mva"], t_data["hv_kv"], t_data["lv_kv"], 
                t_data["impedance"], t_data["ltc_present"], t_data["ltc_range"], t_data["mag_current"])
            st.session_state.calculations["base_values"] = base_values
            
            st.markdown("### Base Calculations")
            col1, col2, col3, col4 = st.columns(4)
            with col1:
                st.metric("HV Current", f"{base_values['hv_rated_current']} A")
            with col2:
                st.metric("LV Current", f"{base_values['lv_rated_current']} A")
            with col3:
                st.metric("Max Fault", f"{base_values['max_through_fault_pu']} pu")
            with col4:
                st.metric("Category", base_values["category"])
            
            st.markdown("---")
            st.markdown("### 87T - Differential Protection (IEEE C37.91-2021)")
            
            diff_settings = calculate_differential_settings(t_data["rated_mva"], t_data["impedance"], t_data["ltc_present"], 
                t_data["ltc_range"], t_data["mag_current"], c_data["hv_ct_ratio"], c_data["lv_ct_ratio"], base_values)
            st.session_state.calculations["differential_87T"] = diff_settings
            
            for setting_name in ["pickup_pu", "slope_1", "slope_2", "harmonic_2nd", "harmonic_5th", "high_set"]:
                if setting_name in diff_settings:
                    s = diff_settings[setting_name]
                    col1, col2, col3 = st.columns([1, 1, 1.2])
                    with col1:
                        st.markdown(f"**{setting_name.replace('_', ' ').title()}**")
                        st.markdown(f"<div class='recommended-value'>{s['recommended']} {s.get('unit', '')}</div>", unsafe_allow_html=True)
                    with col2:
                        value = st.number_input(f"{setting_name}_input", value=float(s["recommended"]), label_visibility="collapsed")
                        s["value_set"] = value
                    with col3:
                        st.markdown(f"<div class='info-box'>{s['standard_ref']}</div>", unsafe_allow_html=True)
            
            st.markdown("---")
            st.markdown("### 51/50 - Overcurrent Protection (IEEE 242-2001)")
            
            oc_settings = calculate_overcurrent_settings(t_data["rated_mva"], t_data["impedance"], t_data["hv_kv"], t_data["lv_kv"], 
                s_data["hv_fault_mva"], s_data["lv_fault_mva"], base_values)
            st.session_state.calculations["overcurrent"] = oc_settings
            
            col1, col2 = st.columns(2)
            with col1:
                st.write(f"**HV 51:** Pickup {oc_settings['hv_51']['pickup']} pu | Trip: {oc_settings['hv_51']['trip_time']} sec")
            with col2:
                st.write(f"**LV 51:** Pickup {oc_settings['lv_51']['pickup']} pu | Trip: {oc_settings['lv_51']['trip_time']} sec")
            
            if oc_settings['coordination_margin'] >= 0.3:
                st.success(f"✅ {oc_settings['coordination_status']} - Margin: {oc_settings['coordination_margin']} sec")
            else:
                st.error(f"❌ {oc_settings['coordination_status']} - Margin: {oc_settings['coordination_margin']} sec")
            
            st.markdown("---")
            st.markdown("### I²t - Through-Fault Protection (IEEE C57.109-1985)")
            
            i2t_settings = calculate_i2t_settings(t_data["rated_mva"], base_values, base_values["max_through_fault_pu"])
            st.session_state.calculations["i2t"] = i2t_settings
            
            col1, col2, col3 = st.columns(3)
            with col1:
                st.metric("Category", i2t_settings['category'])
            with col2:
                st.metric("Thermal Limit", f"{i2t_settings['thermal_limit']} A²s")
            with col3:
                st.metric("Mech. Limit", f"{i2t_settings['mechanical_limit']} A²s")
            
            st.markdown("---")
            if st.button("📄 Generate DOCX Report", use_container_width=True):
                st.session_state.go_to_report = True
    
    # REPORTS
    elif selected == "📄 Reports":
        st.markdown("## Generate DOCX Report")
        if not st.session_state.calculations:
            st.warning("⚠️ Complete calculations first")
        else:
            with st.form("report_form"):
                report_title = st.text_input("Title", value=f"{st.session_state.current_project['name']} - Report")
                approver = st.text_input("Approver (Optional)", placeholder="Leave empty if not ready")
                if st.form_submit_button("📄 Generate DOCX", use_container_width=True):
                    try:
                        from docx import Document
                        from docx.enum.text import WD_ALIGN_PARAGRAPH
                        
                        doc = Document()
                        title = doc.add_heading(report_title, 0)
                        title.alignment = WD_ALIGN_PARAGRAPH.CENTER
                        
                        meta = doc.add_paragraph()
                        meta.add_run(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M')}\\n").bold = True
                        meta.add_run(f"Engineer: {st.session_state.current_project['engineer']}\\n")
                        if approver:
                            meta.add_run(f"Approver: {approver}")
                        meta.alignment = WD_ALIGN_PARAGRAPH.CENTER
                        
                        doc.add_paragraph("_" * 80)
                        
                        # Transformer Data
                        doc.add_heading("1. Transformer Data", 1)
                        t_data = st.session_state.transformer_data
                        table = doc.add_table(rows=5, cols=2)
                        table.style = 'Light Grid'
                        table.rows[0].cells[0].text = "Parameter"
                        table.rows[0].cells[1].text = "Value"
                        table.rows[1].cells[0].text = "Rated Power"
                        table.rows[1].cells[1].text = f"{t_data['rated_mva']} MVA"
                        table.rows[2].cells[0].text = "HV/LV Voltage"
                        table.rows[2].cells[1].text = f"{t_data['hv_kv']}/{t_data['lv_kv']} kV"
                        table.rows[3].cells[0].text = "Impedance"
                        table.rows[3].cells[1].text = f"{t_data['impedance']}%"
                        table.rows[4].cells[0].text = "LTC"
                        table.rows[4].cells[1].text = f"Yes (±{t_data['ltc_range']}%)" if t_data['ltc_present'] else "No"
                        
                        # Differential Settings
                        doc.add_heading("2. Differential Protection (87T)", 1)
                        diff = st.session_state.calculations.get("differential_87T", {})
                        table2 = doc.add_table(rows=1, cols=3)
                        table2.style = 'Light Grid'
                        table2.rows[0].cells[0].text = "Setting"
                        table2.rows[0].cells[1].text = "Recommended"
                        table2.rows[0].cells[2].text = "Value Set"
                        for k, v in diff.items():
                            if isinstance(v, dict) and "recommended" in v:
                                row = table2.add_row()
                                row.cells[0].text = k.replace("_", " ").title()
                                row.cells[1].text = str(v.get("recommended", ""))
                                row.cells[2].text = str(v.get("value_set", ""))
                        
                        # Overcurrent Settings
                        doc.add_heading("3. Overcurrent Protection (51/50)", 1)
                        oc = st.session_state.calculations.get("overcurrent", {})
                        p = doc.add_paragraph()
                        p.add_run(f"HV Pickup: {oc.get('hv_51', {}).get('pickup', 'N/A')} pu | Trip: {oc.get('hv_51', {}).get('trip_time', 'N/A')} sec\\n")
                        p.add_run(f"LV Pickup: {oc.get('lv_51', {}).get('pickup', 'N/A')} pu | Trip: {oc.get('lv_51', {}).get('trip_time', 'N/A')} sec\\n")
                        p.add_run(f"Coordination: {oc.get('coordination_status', 'N/A')} (Margin: {oc.get('coordination_margin', 'N/A')} sec)")
                        
                        # I²t Settings
                        doc.add_heading("4. Through-Fault I²t", 1)
                        i2t = st.session_state.calculations.get("i2t", {})
                        p2 = doc.add_paragraph()
                        p2.add_run(f"Category: {i2t.get('category', 'N/A')}\\n")
                        p2.add_run(f"Thermal Limit: {i2t.get('thermal_limit', 'N/A')} A²s\\n")
                        p2.add_run(f"Mechanical Limit: {i2t.get('mechanical_limit', 'N/A')} A²s")
                        
                        Path("reports").mkdir(exist_ok=True)
                        filename = f"reports/{st.session_state.current_project['name'].replace(' ', '_')}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.docx"
                        doc.save(filename)
                        
                        with open(filename, "rb") as f:
                            doc_bytes = f.read()
                        
                        st.success("✅ Report generated!")
                        st.download_button(label="📥 Download DOCX", data=doc_bytes, file_name=filename.split("/")[-1], 
                            mime="application/vnd.openxmlformats-officedocument.wordprocessingml.document", use_container_width=True)
                    except ImportError:
                        st.error("❌ python-docx not installed: pip install python-docx")
    
    # SETTINGS
    elif selected == "⚙️ Settings":
        st.markdown("## Settings")
        theme = st.selectbox("Theme", ["Light", "Dark", "System"], index=0)
        language = st.selectbox("Language", ["English", "Spanish", "French"], index=0)
        st.info("**Relay Settings Assistant v1.0** - IEEE C37.91 & IEEE 242 compliant")

# MAIN
if __name__ == "__main__":
    init_database()
    try:
        register_user("engineer@company.com", "Test@123")
    except:
        pass
    
    if not st.session_state.logged_in:
        login_page()
    else:
        main_app()
