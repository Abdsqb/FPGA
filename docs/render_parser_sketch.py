"""Optional documentation utility: python3 docs/render_parser_sketch.py.
Requires reportlab; it is not a runtime or test dependency of the FPGA project.
"""
from pathlib import Path
from math import atan2, cos, sin, pi
from reportlab.pdfgen import canvas
from reportlab.lib.pagesizes import A4, landscape
from reportlab.lib.colors import HexColor

dest = Path(__file__).with_name('parser-state-machine.pdf')
c = canvas.Canvas(str(dest), pagesize=landscape(A4))
c.setTitle('Amirlan - ITCH parser state-machine sketch - November 8, 2026')
ink = HexColor('#15263d')
blue = HexColor('#175b91')
c.setFillColor(ink)
c.setFont('Helvetica-Bold', 23)
c.drawString(45, 549, 'ITCH parser - state-machine sketch')
c.setFont('Helvetica', 11)
c.drawString(45, 527, 'Amirlan / CompE     |     November 8, 2026     |     Implemented decoder')
c.setFont('Helvetica', 10)
c.drawString(45, 503, 'Input: one framed ITCH body, one byte per cycle while in_valid = 1. Outputs match Spec v1.')

def text(x,y,s,size=9,bold=False):
    c.setFillColor(ink)
    c.setFont('Helvetica-Bold' if bold else 'Helvetica',size)
    c.drawString(x,y,s)

def box(x,y,title,lines):
    c.setStrokeColor(blue); c.setFillColor(HexColor('#edf4fa'))
    c.roundRect(x,y,140,65,8,fill=1,stroke=1)
    text(x+12,y+44,title,12,True)
    for n,line in enumerate(lines): text(x+12,y+27-12*n,line)

def arrow(points,label=None,lx=0,ly=0):
    c.setStrokeColor(blue); c.setLineWidth(1.4)
    p=c.beginPath(); p.moveTo(*points[0])
    for point in points[1:]: p.lineTo(*point)
    c.drawPath(p)
    x,y=points[-1]; a=atan2(y-points[-2][1],x-points[-2][0])
    for d in [-pi/6,pi/6]: c.line(x,y,x-7*cos(a+d),y-7*sin(a+d))
    if label: text(lx,ly,label,8)

box(45,365,'IDLE',['Waiting for type byte','Latch target locate'])
box(245,365,'COLLECT',['Store bytes as they come','Counter advances per byte'])
box(445,365,'VALIDATE',['Type / length / locate / side','valid = 1 for this cycle if good'])
box(245,220,'DRAIN',['Discard remaining bytes','Wait for last'])
arrow([(185,397),(245,397)],'first',202,405)
arrow([(385,397),(445,397)],'last',407,405)
arrow([(515,430),(515,468),(315,468),(315,430)],'next first byte arrives in this cycle: no gap',330,475)
arrow([(515,365),(515,320),(115,320),(115,365)],'otherwise back to IDLE (bad or foreign: no valid pulse)',330,328)
arrow([(315,365),(315,285)],'framing / oversize error',326,298)
arrow([(245,250),(115,250),(115,365)],'last',150,260)
text(620,420,'Outputs (Spec v1)',10,True)
text(620,404,'valid: one cycle per message')
text(620,390,'msg_type[1:0]: 0 A, 1 E, 2 X, 3 D')
text(620,376,'order_ref[63:0]: full wire ref')
text(620,362,'side: 0 buy, 1 sell (A only)')
text(620,348,'shares[31:0], price[31:0]')
text(450,268,'No backpressure (as in Spec v1): a byte is taken',10,True)
text(450,252,'every cycle in_valid = 1, in every state.')
text(450,235,'clear from any state returns to IDLE on the clock edge.')
text(45,195,'Boundary cases',11,True)
text(45,179,'First and last together: IDLE -> VALIDATE. Missing first: IDLE -> DRAIN (or IDLE if also last).')
text(45,164,'In COLLECT, a second first or a 37th byte rejects the frame. If that byte is also last, return directly to IDLE.')
text(45,149,'Unsupported type, wrong length or bad side never pulses valid. Foreign locate is filtered.')
text(45,126,'Worked Add Order',11,True)
text(45,110,'36 bytes: A / locate 1 / ref 42 / Buy / 100 shares / price 1,502,500 ($150.2500).')
text(45,95,'After the last byte at edge L: valid is high for one cycle; the next message may start in that cycle.')
c.setStrokeColor(HexColor('#b6c6d8')); c.line(45,80,797,80)
text(45,62,'Scope: hw/itch_parser.ml. MoldUDP64 framing is a separate proposed adapter, not implemented here.',9,True)
text(45,47,'Full contract and transport FSM: docs/parser-interface.md. Tests: hw/test/test_itch_parser.ml.',9)
c.showPage(); c.save()
print(dest)
