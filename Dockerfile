# Start from a clean Python environment
FROM python:3.9-slim

# Set the working directory inside the container
WORKDIR /app

# Copy all local files into the container
COPY . /app

# Install Flask
RUN pip install Flask

# Expose port 5000
EXPOSE 5000

# Run the application
CMD ["python", "app.py"]

