# Guion del pitch — Nodo Ruta (5 minutos, 3 diapositivas)

Público: empresas, no técnico. Las mismas notas están en el PowerPoint (vista Moderador). Lo que va entre paréntesis es apoyo por si preguntan; no se dice de entrada.

## 1. El problema · 0:00 – 1:15

Buenos días. Somos Los Jensen y les presentamos Nodo Ruta.

Imaginen una empresa de entregas: sus clientes entran a consultar dónde está su pedido. Ese servicio funcionaba en un solo servidor.

Eso tenía tres riesgos. Si ese servidor fallaba, o una actualización salía mal, todo se detenía. La información de los pedidos vivía dentro del mismo programa, así que se podía perder. Y nunca se había probado cómo recuperarlo ni cuánto tardaría.

Para el negocio eso es simple: clientes sin respuesta y nadie que sepa cuándo vuelve el servicio.

Nuestro objetivo fue uno solo: que si algo falla, el cliente no lo note.

## 2. La solución · 1:15 – 2:45

Así lo resolvimos, en la nube de Amazon.

Los clientes ya no llegan directo al servicio, sino a un "recepcionista" automático que reparte las consultas y solo las envía a lo que está funcionando bien.

En lugar de un servidor, hay tres copias del servicio repartidas en dos centros de datos distintos. Si uno tiene un problema, el otro sigue atendiendo.

Y la información de los pedidos ya no vive dentro del programa: está guardada aparte, protegida y con copias de respaldo.

¿Qué gana la empresa? Un servicio siempre disponible, que se recupera solo, y que se paga por uso: se enciende cuando se necesita y se apaga con un comando.

(Por si preguntan: recepcionista = balanceador ALB; copias = Kubernetes en Amazon EKS; datos = Amazon RDS PostgreSQL; todo se crea con Terraform.)

## 3. Resultados y costo · 2:45 – 5:00

No nos quedamos en la teoría: lo comprobamos en la nube rompiendo cosas a propósito. Durante cada prueba consultábamos el servicio cada segundo, como lo haría un cliente.

Primero apagamos una copia del servicio: en unos 7 segundos se creó una nueva, sola, y mientras tanto las demás siguieron atendiendo.

Después apagamos un servidor completo: cero consultas perdidas, porque las copias del otro centro de datos siguieron respondiendo.

Luego actualizamos el sistema con los clientes conectados: se cambió copia por copia, con cero cortes.

Y por último dañamos la información a propósito: en menos de 15 minutos quedó restaurada, idéntica a la original.

¿Y cuánto cuesta? Como la nube cobra por hora, se enciende con un comando cuando se necesita y se apaga con otro. Una sesión de 4 horas cuesta alrededor de 1,2 dólares, y todo el proyecto usó unos 16 de los 140 dólares que teníamos en créditos, sin pagar nada de bolsillo.

En resumen: pasamos de un servidor frágil a un servicio que siempre está disponible y se recupera solo.

Muchas gracias. Quedamos atentos a sus preguntas.

