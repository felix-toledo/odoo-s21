from odoo import http, fields
from odoo.http import request
from datetime import datetime, timedelta
import json

class ApiBookingDashboard(http.Controller):
    
    # ==================== RESERVAS ====================
    
    @http.route('/api/booking/reserve', type='json', auth='user', methods=['POST'])
    def reserve_booking(self):
        """
        Crear una reserva sin pasar por el portal de Odoo.
        
        POST /api/booking/reserve
        {
            "booking_type_id": 1,
            "resource_id": 2,
            "date_start": "2024-05-10 14:00:00",
            "partner_id": 3,  (opcional, usa current user si no está)
            "name": "Mi reserva"
        }
        """
        try:
            data = request.get_json_data()
            
            booking_type_id = data.get('booking_type_id')
            resource_id = data.get('resource_id')
            date_start = data.get('date_start')
            partner_id = data.get('partner_id')
            name = data.get('name', 'Reserva')
            
            # Validar campos requeridos
            if not all([booking_type_id, resource_id, date_start]):
                return {
                    'success': False,
                    'error': 'Faltan campos requeridos: booking_type_id, resource_id, date_start'
                }
            
            # Obtener tipo de reserva para calcular duración
            booking_type = request.env['resource.booking.type'].browse(booking_type_id)
            if not booking_type.exists():
                return {'success': False, 'error': 'Tipo de reserva no encontrado'}
            
            # Calcular fecha fin basada en duración
            start = datetime.fromisoformat(date_start.replace('Z', '+00:00'))
            duration_minutes = booking_type.duration or 30
            end = start + timedelta(minutes=duration_minutes)
            
            # Usar partner actual si no se proporciona
            if not partner_id:
                partner_id = request.env.user.partner_id.id
            
            # Crear la reserva
            booking = request.env['resource.booking'].create({
                'name': name,
                'booking_type_id': booking_type_id,
                'resource_id': resource_id,
                'partner_id': partner_id,
                'date_start': start,
                'date_end': end,
                'state': 'draft',
            })
            
            return {
                'success': True,
                'booking_id': booking.id,
                'booking_name': booking.name,
                'date_start': booking.date_start.isoformat(),
                'date_end': booking.date_end.isoformat(),
                'message': 'Reserva creada exitosamente'
            }
        except Exception as e:
            return {
                'success': False,
                'error': str(e)
            }
    
    @http.route('/api/booking/types', type='json', auth='user', methods=['GET'])
    def get_booking_types(self):
        """
        Obtener todos los tipos de reserva disponibles
        GET /api/booking/types
        """
        try:
            types = request.env['resource.booking.type'].search([])
            data = [{
                'id': t.id,
                'name': t.name,
                'duration': t.duration,
                'description': t.description or '',
            } for t in types]
            return {'success': True, 'data': data}
        except Exception as e:
            return {'success': False, 'error': str(e)}
    
    @http.route('/api/booking/resources', type='json', auth='user', methods=['GET'])
    def get_resources(self):
        """
        Obtener todos los recursos disponibles
        GET /api/booking/resources
        """
        try:
            resources = request.env['resource.resource'].search([])
            data = [{
                'id': r.id,
                'name': r.name,
                'company_id': r.company_id.id if r.company_id else None,
            } for r in resources]
            return {'success': True, 'data': data}
        except Exception as e:
            return {'success': False, 'error': str(e)}
    
    @http.route('/api/booking/available-slots', type='json', auth='user', methods=['POST'])
    def get_available_slots(self):
        """
        Obtener slots disponibles para una fecha y tipo de reserva
        POST /api/booking/available-slots
        {
            "booking_type_id": 1,
            "date": "2024-05-10",
            "resource_id": 2
        }
        """
        try:
            data = request.get_json_data()
            booking_type_id = data.get('booking_type_id')
            date_str = data.get('date')
            resource_id = data.get('resource_id')
            
            booking_type = request.env['resource.booking.type'].browse(booking_type_id)
            duration = booking_type.duration or 30
            
            # Horario de atención: 8am - 6pm
            slots = []
            start_hour = 8
            end_hour = 18
            
            for hour in range(start_hour, end_hour):
                for minute in [0, 30]:
                    slot_time = f"{hour:02d}:{minute:02d}:00"
                    slots.append({
                        'time': slot_time,
                        'datetime': f"{date_str}T{slot_time}",
                        'available': True  # En producción, verificar conflictos
                    })
            
            return {'success': True, 'slots': slots}
        except Exception as e:
            return {'success': False, 'error': str(e)}
    
    @http.route('/api/booking/my-bookings', type='json', auth='user', methods=['GET'])
    def get_my_bookings(self):
        """
        Obtener mis reservas
        GET /api/booking/my-bookings
        """
        try:
            partner_id = request.env.user.partner_id.id
            bookings = request.env['resource.booking'].search([
                ('partner_id', '=', partner_id)
            ], order='date_start desc')
            
            data = [{
                'id': b.id,
                'name': b.name,
                'booking_type': b.booking_type_id.name,
                'resource': b.resource_id.name,
                'date_start': b.date_start.isoformat(),
                'date_end': b.date_end.isoformat(),
                'state': b.state,
            } for b in bookings]
            
            return {'success': True, 'data': data}
        except Exception as e:
            return {'success': False, 'error': str(e)}
    
    # ==================== DASHBOARD ====================
    
    @http.route('/api/dashboard/summary', type='json', auth='user', methods=['GET'])
    def get_dashboard_summary(self):
        """
        Obtener resumen del dashboard para el administrador
        GET /api/dashboard/summary
        """
        try:
            # Total de ventas hoy
            today = fields.Date.today()
            sales_today = request.env['sale.order'].search([
                ('date_order', '>=', f"{today} 00:00:00"),
                ('state', 'in', ['done', 'sale'])
            ])
            total_sales_today = sum(s.amount_total for s in sales_today)
            
            # Stock total
            stock_moves = request.env['stock.quant'].search([])
            total_stock_value = sum(q.quantity * q.cost for q in stock_moves)
            
            # Órdenes pendientes
            pending_orders = request.env['sale.order'].search_count([
                ('state', '=', 'draft')
            ])
            
            # Turnos de hoy
            bookings_today = request.env['resource.booking'].search_count([
                ('date_start', '>=', f"{today} 00:00:00"),
                ('date_start', '<', f"{today} 23:59:59"),
            ])
            
            return {
                'success': True,
                'data': {
                    'total_sales_today': total_sales_today,
                    'stock_value': total_stock_value,
                    'pending_orders': pending_orders,
                    'bookings_today': bookings_today,
                }
            }
        except Exception as e:
            return {'success': False, 'error': str(e)}
    
    @http.route('/api/dashboard/stock', type='json', auth='user', methods=['GET'])
    def get_stock(self):
        """
        Obtener stock de productos
        GET /api/dashboard/stock
        """
        try:
            products = request.env['product.product'].search_read(
                [], 
                fields=['id', 'name', 'qty_available', 'list_price', 'standard_price']
            )
            
            data = [{
                'id': p['id'],
                'name': p['name'],
                'qty_available': p['qty_available'],
                'list_price': p['list_price'],
                'cost': p['standard_price'],
                'margin': p['list_price'] - p['standard_price'] if p['list_price'] > 0 else 0,
            } for p in products]
            
            return {'success': True, 'data': data}
        except Exception as e:
            return {'success': False, 'error': str(e)}
    
    @http.route('/api/dashboard/sales', type='json', auth='user', methods=['GET'])
    def get_sales(self):
        """
        Obtener órdenes de venta
        GET /api/dashboard/sales
        """
        try:
            sales = request.env['sale.order'].search_read(
                [('state', 'in', ['done', 'sale'])],
                fields=['id', 'name', 'amount_total', 'date_order', 'partner_id', 'state'],
                limit=100,
                order='date_order desc'
            )
            
            data = [{
                'id': s['id'],
                'order_number': s['name'],
                'amount': s['amount_total'],
                'date': s['date_order'],
                'customer': s['partner_id'][1] if s['partner_id'] else 'Sin cliente',
                'state': s['state'],
            } for s in sales]
            
            return {'success': True, 'data': data}
        except Exception as e:
            return {'success': False, 'error': str(e)}
    
    @http.route('/api/dashboard/sales-trend', type='json', auth='user', methods=['GET'])
    def get_sales_trend(self):
        """
        Obtener tendencia de ventas últimos 30 días
        GET /api/dashboard/sales-trend
        """
        try:
            from datetime import datetime, timedelta
            today = datetime.now().date()
            thirty_days_ago = today - timedelta(days=30)
            
            sales = request.env['sale.order'].search([
                ('date_order', '>=', f"{thirty_days_ago} 00:00:00"),
                ('state', 'in', ['done', 'sale'])
            ])
            
            # Agrupar por fecha
            trend = {}
            for sale in sales:
                date_key = sale.date_order.date().isoformat()
                if date_key not in trend:
                    trend[date_key] = {'amount': 0, 'count': 0}
                trend[date_key]['amount'] += sale.amount_total
                trend[date_key]['count'] += 1
            
            return {'success': True, 'data': trend}
        except Exception as e:
            return {'success': False, 'error': str(e)}
    
    @http.route('/api/dashboard/revenue', type='json', auth='user', methods=['GET'])
    def get_revenue(self):
        """
        Obtener ingresos totales por período
        GET /api/dashboard/revenue?period=month  (day, month, year)
        """
        try:
            period = request.httprequest.args.get('period', 'month')
            today = datetime.now().date()
            
            if period == 'day':
                date_from = today
            elif period == 'month':
                date_from = today.replace(day=1)
            elif period == 'year':
                date_from = today.replace(month=1, day=1)
            else:
                date_from = today - timedelta(days=30)
            
            sales = request.env['sale.order'].search([
                ('date_order', '>=', f"{date_from} 00:00:00"),
                ('state', 'in', ['done', 'sale'])
            ])
            
            total_revenue = sum(s.amount_total for s in sales)
            
            return {
                'success': True,
                'data': {
                    'period': period,
                    'total_revenue': total_revenue,
                    'order_count': len(sales),
                    'average_order': total_revenue / len(sales) if sales else 0,
                }
            }
        except Exception as e:
            return {'success': False, 'error': str(e)}
