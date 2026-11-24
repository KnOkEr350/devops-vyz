from django.db import migrations, models


class Migration(migrations.Migration):
    initial = True
    dependencies = []
    operations = [
        migrations.CreateModel(
            name="Note",
            fields=[
                ("id", models.BigAutoField(primary_key=True, serialize=False, auto_created=True, verbose_name="ID")),
                ("text", models.CharField(max_length=180)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
            ],
        ),
    ]
